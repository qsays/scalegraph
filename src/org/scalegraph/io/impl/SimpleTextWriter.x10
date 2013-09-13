/*
 *  This file is part of the ScaleGraph project (https://sites.google.com/site/scalegraph/).
 * 
 *  This file is licensed to You under the Eclipse Public License (EPL);
 *  You may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *      http://www.opensource.org/licenses/eclipse-1.0.php
 * 
 *  (C) Copyright ScaleGraph Team 2011-2012.
 */
package org.scalegraph.io.impl;

import x10.util.Team;
import x10.util.concurrent.Monitor;

import org.scalegraph.test.STest;
import org.scalegraph.util.SString;
import org.scalegraph.util.MemoryChunk;
import org.scalegraph.util.GrowableMemory;
import org.scalegraph.util.DistMemoryChunk;
import org.scalegraph.util.SStringBuilder;
import org.scalegraph.util.Parallel;
import org.scalegraph.util.MathAppend;
import org.scalegraph.io.NamedDistData;
import org.scalegraph.id.Type;
import org.scalegraph.io.FileWriter;

public class SimpleTextWriter {
	/*hedder 1 line
	 * string with double quotation 
	 * "name1 <int>","name2 <.... namex : NamedDistData.name
	 * path :directory (make a directory  (hogenameprovider
	 * file num = place num ( each place writes files)
	 * */
	
	public static CHUNK_SIZE = 128*1024;

	private static class ParallelWriter[T] {
		private var frontBuffer :MemoryChunk[SStringBuilder];
		private var backBuffer :MemoryChunk[SStringBuilder];
		private val fw :FileWriter;
		private val strClousure :MemoryChunk[(sb :SStringBuilder, idx :Long) => void];
		private val monitor = new Monitor();
		private var numLauchTasks :Int = 0;
		
		public def this(fw :FileWriter, strClousure :MemoryChunk[(sb :SStringBuilder, idx :Long) => void]) {
			val nthreads = Runtime.NTHREADS;
			this.frontBuffer = new MemoryChunk[SStringBuilder](nthreads, (i :Long) => new SStringBuilder());
			this.backBuffer = new MemoryChunk[SStringBuilder](nthreads, (i :Long) => new SStringBuilder());
			this.fw = fw;
			this.strClousure = strClousure;
		}
		
		private def cycleBuffers(numTasksToLaunch :Int) {
			// wait for completion of sub tasks
			monitor.lock();
			while(numLauchTasks > 0) {
				monitor.await();
			}
			numLauchTasks = numTasksToLaunch;
			monitor.unlock();
			val tmp = backBuffer;
			backBuffer = frontBuffer;
			frontBuffer = tmp;
		}
		
		private def notifySubtaskCompletion() {
			monitor.lock();
			if(--numLauchTasks == 0)
				monitor.release();
			else
				monitor.unlock();
		}
		
		private def makeString(range :LongRange) {
			Parallel.iter(range, (tid :Long, r :LongRange) => {
				val buf = backBuffer(tid);
				val numColumns = strClousure.size();
				if(numColumns == 0L) return ;
				for(i in r) {
					strClousure(0)(buf,i);
					/*					for(c in 0..(numColumns-2)) {
					 * strClousure(c)(buf, i);
					 * buf.add(',');
					 * }
					 * strClousure(numColumns-1)(buf, i);
					 * buf.add('\n');
				 */				}
			});
		}
		
		private def subtask() {
			for(tid in frontBuffer.range()) {
				val bytes = frontBuffer(tid).result().bytes();
				//	STest.println(here.id + " => Write " + bytes.size() + " bytes");
				fw.write(bytes);
				frontBuffer(tid).clear();
			}
			
			notifySubtaskCompletion();
		}
		
		public def write(numLines :Long) {
			val nthreads = Runtime.NTHREADS;
			finish for(var start :Long = 0; start < numLines; start += CHUNK_SIZE * nthreads) {
				val end = MathAppend.min(start + CHUNK_SIZE * nthreads, numLines) - 1;
				makeString(start..end);
				cycleBuffers(1);
				async subtask();
			}
		}
	}

	/* header
	 * "Name1 <Int>" ,"Name2...
	 */
	
	public static def write[T](team :Team, path :String, data :NamedDistData, header :String, kuro :(source :Long, target :Long, weight :T) => String){
		write[T](team,SString(path),data,SString(header),(source :Long, target :Long, weight :T) => {return SString(kuro(source,target,weight));} );
	}
	public static def write[T](team :Team, path :SString, data :NamedDistData, header :SString, kuro :(source :Long, target :Long, weight :T) => SString){
		val fman = FileNameProvider.createForWrite(path,true);
		// create directory if it is not exists.
		fman.mkdir();

		val typeId = data.typeId();
		val colNum = typeId.size;
		val atts = new MemoryChunk[CSVAttributeHandler](colNum,
				(i :Long) => CSVAttributeHandler.create(typeId(i as Int), false));
		val dmc = data.data();
		
		team.placeGroup().broadcastFlat(() => {
			val teamRole = team.role()(0);
			val teamSize = team.size();
			
			val makeStringClosures = new GrowableMemory[(sb :SStringBuilder, idx :Long) => void]();

			//			for (i in 0..(colNum-1)) {
			//				makeStringClosures.add(att.makeStringClosure(kuro,dmc(0),dmc(1),dmc(2) ));
			val mc1 = dmc(0) as DistMemoryChunk[Long]; val mc2 = dmc(1) as DistMemoryChunk[Long]; val mc3 = dmc(2) as DistMemoryChunk[T];
			makeStringClosures.add( (sb :SStringBuilder, idx :Long) => { sb.add( kuro(mc1()(idx),mc2()(idx),mc3()(idx) ) ); } );
			//			}
			
			val fw = fman.openWrite(teamRole);
			
			if (teamRole == 0){
				// write header
				val ssb = new SStringBuilder();
				for (i in 0..(colNum-1)) {
					if( data.typeId()(i) == Type.String ){
						ssb.add("\"" + data.name()(i) + "<" + Type.typeNameStr(data.typeId()(i) ) + ">\"" + ( i != colNum-1 ?  "," : "\n"));
					}else{
						ssb.add("" + data.name()(i) + "<" + Type.typeNameStr(data.typeId()(i) ) + ">" + ( i != colNum-1 ?  "," : "\n"));
					}
				}
				fw.write(ssb.result().bytes());
			}
			
			val writer = new ParallelWriter[T](fw, makeStringClosures.raw());
			writer.write(atts(0).localSizeOf(dmc(0)));
			fw.close();
		});
	}

}	

