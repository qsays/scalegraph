/* 
 *  This file is part of the ScaleGraph project (http://scalegraph.org).
 * 
 *  This file is licensed to You under the Eclipse Public License (EPL);
 *  You may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *      http://www.opensource.org/licenses/eclipse-1.0.php
 * 
 *  (C) Copyright ScaleGraph Team 2011-2012.
 */

package org.scalegraph.metrics;

import x10.compiler.Ifndef;
import x10.compiler.Inline;
import x10.compiler.Native;
import x10.util.concurrent.Lock;
//import x10.io.SerialData;
import x10.io.Serializer;
import x10.io.Deserializer;
import x10.io.File;
import x10.io.FileReader;
import x10.io.IOException;
import x10.util.ArrayList;
//import x10.util.IndexedMemoryChunk;
import x10.util.concurrent.AtomicLong;
import x10.util.Team;
import x10.xrx.Runtime;

import org.scalegraph.util.Dist2D;
import org.scalegraph.fileread.DistributedReader;
import org.scalegraph.blas.DistSparseMatrix;
import org.scalegraph.graph.Graph;
import org.scalegraph.blas.SparseMatrix;
import org.scalegraph.util.tuple.*;
import org.scalegraph.util.DistMemoryChunk;
import org.scalegraph.util.MemoryChunk;
import org.scalegraph.util.Bitmap2;
import org.scalegraph.Config;
import x10.util.concurrent.AtomicDouble;
import org.scalegraph.graph.id.OnedR;

public type Vertex = Long;
public type Distance = Long;

/**
 * A class for computing betweenness centrality for large-scale unweigheted graphs.
 * The implementation is based on Brandes's alogorthm[1] and Edmonds' algorithm[2].
 * The linear-scaling technique[3] is also available for improving the estimation result.
 * 
 * <br><br>
 * Reference:
 * <br>[1] Brandes, Ulrik. "A faster algorithm for betweenness centrality*." Journal of Mathematical Sociology 25.2 (2001): 163-177.
 * <br>[2] Edmonds, Nick, Torsten Hoefler, and Andrew Lumsdaine. "A space-efficient parallel algorithm for computing betweenness centrality in distributed memory." High Performance Computing (HiPC), 2010 International Conference on. IEEE, 2010.
 * <br>[3] Geisberger, Robert, Peter Sanders, and Dominik Schultes. "Better approximation of betweenness centrality." Proceedings of the 10th Workshop on Algorithm Engineering and Experimentation (ALENEX08). To appear. 2008.
 */
public class DistBetweennessCentrality implements x10.io.CustomSerialization {
    private val team: Team;
    private val lgl: Int;
    private val lgc: Int;
    private val lgr: Int;
    private val role: Int;
    private val localGraph: SparseMatrix[Long];
    
    public static class LocalState {
        // 1D CSR graph
        val _distSparseMatrix: DistSparseMatrix[Long];
        
        val _currentSource: Cell[Vertex];
        val _queues: MemoryChunk[Bitmap2];
        
        // poniters of current queue and next queue
        val _qPointer: Cell[Int];
        
        // current distance from source
        val _currentLevel: Cell[Long];
        
        // the number of local vertices
        val _numLocalVertices: Long;
        
        // betweenness centrality score
        val _score: MemoryChunk[Double];
        
        // the number of vertices in graph
        val _numberOfVerticesInGraph: Long;
        val _isNormalize: Boolean;
        
        // linear-scaling flag
        val _linearScale: Boolean;
        
        /* Sources stuffs */
        val _sources: Rail[Vertex];
        val _sourceRange: LongRange;
        val _numSource: Long;
        
        val _NUM_TASK: Int;
        val _BUFFER_SIZE: Int;
        val _ALIGN = 64;
        val _CONGRUENT = false;
        
        // distance from source
        val _distanceMap: MemoryChunk[Long];
        
        // predecessor list in bfs-graph
        val _predMap: MemoryChunk[ArrayList[Long]];
        
        // the number of predecessor
        val _successorCount: MemoryChunk[Long];
        
        // the number of geodesic paths passing through a vertex
        val _pathCount: MemoryChunk[Long];
        
        // vertex dependecies
        val _dependencies: MemoryChunk[Double];
        val _dependenciesLock: Rail[Lock];
                
        /* Back tracking stuff */
        val _backtrackingQueues: MemoryChunk[Bitmap2];
        val _backtrackingQPointer: Cell[Int];
        // The number of vertex's successor that has called back 
        val _numUpdate: MemoryChunk[Long];
        
        /* Buffer stuffs*/
        val _predBuf: Rail[Rail[ArrayList[Vertex]]];
        val _succBuf: Rail[Rail[ArrayList[Vertex]]];
        val _deltaBuf: Rail[Rail[ArrayList[Double]]];
        val _sigmaBuf: Rail[Rail[ArrayList[Long]]];
        val _muBuf: Rail[Rail[ArrayList[Long]]];
        
        val s2v: OnedR.StoV;
        val d2v: OnedR.DtoV;
        val v2s: OnedR.VtoS;
        
        protected def this(dsm: DistSparseMatrix[Long],
                           buffSize: Int,
                           nAllVerticesInG: Long,
                           nSrc: Long,
                           srcs: Rail[Vertex],
                           srcRange: LongRange,
                           norm: Boolean,
                           linearScale: Boolean) {
            
            val t = dsm.dist().allTeam();
            _BUFFER_SIZE = buffSize;
            _NUM_TASK = Runtime.NTHREADS;
            _distSparseMatrix = dsm;
            _numberOfVerticesInGraph = nAllVerticesInG;
            _numLocalVertices = dsm.ids().numberOfLocalVertexes();
            _isNormalize = norm;
            _linearScale = linearScale;
            _sources = srcs;
            _numSource = nSrc;
            _sourceRange = srcRange;
            _currentSource = new Cell[Vertex](0);
            // _queues = IndexedMemoryChunk.allocateUninitialized[Bitmap2](2,
            //                 _ALIGN,
            //                 _CONGRUENT);
            _queues = MemoryChunk.make[Bitmap2](2);
            _queues(0) = new Bitmap2(_numLocalVertices);
            _queues(1) = new Bitmap2(_numLocalVertices);
            _qPointer = new Cell[Int](0n);
            _currentLevel = new Cell[Long](0);
            
            // _score = IndexedMemoryChunk.allocateZeroed[Double](
            //         _numLocalVertices,
            //         _ALIGN,
            //         _CONGRUENT);
            _score = MemoryChunk.make[Double](_numLocalVertices);
            // _distanceMap = IndexedMemoryChunk.allocateZeroed[Long](
            //         _numLocalVertices,
            //         _ALIGN,
            //         _CONGRUENT);
            _distanceMap = MemoryChunk.make[Long](_numLocalVertices);
            // _predMap =IndexedMemoryChunk.allocateUninitialized[ArrayList[Long]](
            //         _numLocalVertices,
            //         _ALIGN,
            //         _CONGRUENT);
            _predMap = MemoryChunk.make[ArrayList[Long]](_numLocalVertices);
            // _successorCount = IndexedMemoryChunk.allocateUninitialized[Long](
            //         _numLocalVertices,
            //         _ALIGN,
            //         _CONGRUENT);
            _successorCount = MemoryChunk.make[Long](_numLocalVertices);
            // _pathCount = IndexedMemoryChunk.allocateZeroed[Long](
            //         _numLocalVertices, 
            //         _ALIGN, 
            //         _CONGRUENT);
            _pathCount = MemoryChunk.make[Long](_numLocalVertices);
            // _dependencies = IndexedMemoryChunk.allocateZeroed[Double](
            //         _numLocalVertices, 
            //         _ALIGN, 
            //         _CONGRUENT);
            _dependencies = MemoryChunk.make[Double](_numLocalVertices);
            // _dependenciesLock = IndexedMemoryChunk.allocateZeroed[Lock](
            //         _numLocalVertices, 
            //         _ALIGN, 
            //         _CONGRUENT);
            //_dependenciesLock = MemoryChunk.make[Lock](_numLocalVertices);
            _dependenciesLock = Unsafe.allocRailZeroed[Lock](_numLocalVertices);

            // Create queue for updating score
            // _backtrackingQueues = IndexedMemoryChunk.allocateUninitialized[Bitmap2](
            //         2, 
            //         _ALIGN,
            //         _CONGRUENT);
            _backtrackingQueues = MemoryChunk.make[Bitmap2](2);
            _backtrackingQueues(0) = new Bitmap2(_numLocalVertices);
            _backtrackingQueues(1) = new Bitmap2(_numLocalVertices);
            _backtrackingQPointer = new Cell[Int](0n);
            // _numUpdate = IndexedMemoryChunk.allocateZeroed[Long](
            //         _numLocalVertices, 
            //         _ALIGN, 
            //         _CONGRUENT);
            _numUpdate = MemoryChunk.make[Long](_numLocalVertices);
                            
            // Init loop
            for (i in 0..(_numLocalVertices - 1)) {
                val idx = i;
                _distanceMap(idx) = 0L;
              //  _predMap(idx) = null;
                _successorCount(idx) = 0;
                _pathCount(idx) = 0L;
                _numUpdate(idx) = 0;
                _dependencies(idx) = 0D;
                _dependenciesLock(idx) = new Lock();
                _score(idx) = 0D;
            }
            _predBuf = new Rail[Rail[ArrayList[Vertex]]](_NUM_TASK,
                    (Long) => new Rail[ArrayList[Vertex]](t.size(),
                            (Long) => new ArrayList[Vertex](buffSize)));
            _succBuf = new Rail[Rail[ArrayList[Vertex]]](_NUM_TASK,
                    (Long) => new Rail[ArrayList[Vertex]](t.size(),
                            (Long) => new ArrayList[Vertex](buffSize)));
            _deltaBuf = new Rail[Rail[ArrayList[Double]]](_NUM_TASK,
                    (Long) => new Rail[ArrayList[Double]](t.size(),
                            (Long) => new ArrayList[Double](buffSize)));
            _sigmaBuf = new Rail[Rail[ArrayList[Long]]](_NUM_TASK,
                    (Long) => new Rail[ArrayList[Long]](t.size(),
                            (Long) => new ArrayList[Long](buffSize)));
            _muBuf = new Rail[Rail[ArrayList[Long]]](_NUM_TASK,
                    (Long) => new Rail[ArrayList[Long]](t.size(),
                            (Long) => new ArrayList[Long](buffSize)));
            
            s2v = new OnedR.StoV(dsm.ids(), t.role()(0));
            d2v = new OnedR.DtoV(dsm.ids());
            v2s = new OnedR.VtoS(dsm.ids());;
        }
    }
    
    // hold local stat for each place
    private val lch:PlaceLocalHandle[LocalState];
    
    private def this(lch_:PlaceLocalHandle[LocalState]) {
        // Set local state
        lch  = lch_;
        val dsm = lch_()._distSparseMatrix;
        team = 	dsm.dist().allTeam();
        lgl = dsm.ids().lgl;
        lgc = dsm.ids().lgc;
        lgr = dsm.ids().lgr;
        role = team.role(here)(0);
        localGraph = dsm();
    }
    
    ///* Serialize function */
    //public def serialize(): SerialData {
    //    return new SerialData(lch, null);
    //}
    //
    ///* Deserialize function */
    //public def this (serialData: SerialData) {
    //    this(serialData.data as PlaceLocalHandle[LocalState]);
    //}

	public def this(data : Deserializer){
        this( data.readAny() as PlaceLocalHandle[LocalState]);
    }
    
    public def serialize(s:Serializer) {
		s.writeAny(lch);
    }
    
    /* GCC Built-in atomic function interface */
    @Native("c++", "__sync_bool_compare_and_swap((#imc)->raw() + #index, #oldVal, #newVal)")
    private static native def compare_and_swap[T](imc: Rail[T], index: Long, oldVal: T, newVal: T): Boolean;
    
    @Native("c++", "__sync_val_compare_and_swap((#imc)->raw() + #index, #oldVal, #newVal)")
    private static native def compare_and_swap_val[T](imc: Rail[T], index: Long, oldVal: T, newVal: T): T;
    
    @Native("c++", "__sync_fetch_and_add((#imc)->raw() + #index, #value)")
    private static native def fetch_and_add[T](imc: Rail[T], index: Long, value: T): T;
    
    @Native("c++", "__sync_add_and_fetch((#imc)->raw() + #index, #value)")
    private static native def add_and_fetch[T](imc: Rail[T], index: Long, value: T): T;
    
    // /**
    //  * Calculate exact betweenness centrality
    //  * <p> 
    //  * Note: Normalize factor - (N-1)*(N-2) for directed graph and (N-1)*(N-2)/2 for undirected graph
    //  * @param g A graph to compute betweenness centrality
    //  * @param directed how to treat directness of the graph, true - directed, false - directed
    //  * @param attrName name of graph attribute to store betweenness centraltiy score
    //  * @param normalize normalize result
    //  */
    // public static def calculate(g: Graph, directed: Boolean, attrName: String, normalize: Boolean): void {
    //     val sourceRange = 0..(g.numberOfVertices() - 1);
    //     run(g, directed, attrName, normalize, -1, null, sourceRange, false, true);
    // }
    // 
    // /**
    //  * Estimate betweenness centrality, the source vertices will be random selected to number of sources given
    //  * @param g A graph to compute betweenness centrality
    //  * @param directed how to treat directness of the graph, true - directed, false - directed
    //  * @param attrName name of graph attribute to store betweenness centraltiy score
    //  * @param numSource the number of source vertices used to calculate betweenness centrality
    //  * @param linearScale use linear-scaling technique
    //  */
    // public static def estimate(g: Graph, directed: Boolean, attrName: String, numSource: Long, linearScale: Boolean): void {
    //     run(g, directed, attrName, false, numSource, null, 0..(-1 as Long), linearScale, false);
    // }
    // 
    // /**
    //  * Estimate betweenness centrality
    //  * @param g A graph to compute betweenness centrality
    //  * @param directed how to treat directness of the graph, true - directed, false - directed
    //  * @param attrName name of graph attribute to store betweenness centraltiy score
    //  * @param sources the array of source vertices to calculate betweenness centrality
    //  * @param linearScale use linear-scaling technique
    //  */
    // public static def estimate(g: Graph, directed: Boolean, attrName: String, sources: Rail[Vertex], linearScale: Boolean): void {
    //     run(g, directed, attrName, false, -1, sources, 0..(-1 as Long), linearScale, false);
    // }
    // 
    // /**
    //  * Estimate betweenness centrality
    //  * @param g A graph to compute betweenness centrality
    //  * @param directed how to treat directness of the graph, true - directed, false - directed
    //  * @param attrName name of graph attribute to store betweenness centraltiy score
    //  * @param sourceRange the range of source vertex ids to calculate betweenness centrality
    //  * @param linearScale use linear-scaling technique
    //  */
    // public static def estimate(g: Graph, directed: Boolean, attrName: String, sourceRange: LongRange, linearScale: Boolean): void {
    //     run(g, directed, attrName, false, -1, null, sourceRange, linearScale, false);
    // }
    
    /**
     * Clear memory used by DistBetweennessCentrality
     */
    public def del() {
        // TODO: clear all reference
    }

    /* Should be used by designated API */
    public static def run(csr: DistSparseMatrix[Long], numberOfVertices: Long, directed: Boolean, normalize: Boolean, numSource: Long, sources: Rail[Vertex], sourceRange: LongRange, linearScale: Boolean, isExactBc: Boolean) {
        val team = csr.dist().allTeam();;
        val places = team.placeGroup();
        // Represent graph as CSR
        // val csr = g.createDistEdgeIndexMatrix(
        //         Dist2D.make1D(team, Dist2D.DISTRIBUTE_COLUMNS),
        //         directed,
        //         true);        
        // Create local state for BC on each place in team
        val transBufferSize = (1 << 10);
        
        // Workaround for init sources for exteral API
        val N = numberOfVertices;
        val numSource_ = isExactBc ? -1L: numSource;
        val sources_ = isExactBc ? null: sources;
        val sourceRange_ = isExactBc ? 0..(N - 1): sourceRange;
        val stopWatch = Config.get().stopWatch();
        ///stopWatch.lap("Graph construction");
        val localState = PlaceLocalHandle.make[LocalState](places, 
                () => { 
                    return (new LocalState(csr,
                            transBufferSize as Int,
                            N,
                            numSource_,
                            sources_,
                            sourceRange_,
                            normalize,
                            linearScale));
                });
        val bc = new DistBetweennessCentrality(localState);
        bc.start();
        // Normalize result
       
        if (normalize) {
            finish for (p in places) {
                at (p) async {
                    internalIter(0..(bc.lch()._numLocalVertices -1), (i: Long) => {
                        val score = bc.lch()._score(i);
                        var frac: Double = (N - 1) * (N - 2);
                        if (!directed)
                            frac /= 2D;
                        bc.lch()._score(i) = score / (frac);
                    });
                }
            }
        } else if (!directed && isExactBc) {
            // Undirected grapth and exact bc --> result divive by 2
            finish for (p in places) {
                at (p) async {
                    internalIter(0..(bc.lch()._numLocalVertices -1), (i: Long) => {
                        val score = bc.lch()._score(i);
                        bc.lch()._score(i) = score / 2D;
                    });
                }
            }
        }
        // Return result as a graph attribute
        val result = new DistMemoryChunk[Double](places, () => {
            // val r = MemoryChunk.make[Double](localState()._score.length());
            // for (i in 0..(r.size() -1))
            //     r(i) = localState()._score(i);
            // return r;
            return localState()._score;
        });
        // g.setVertexAttribute[Double](attrName, result);
        // //TODO: Remove this line for release
        // // bc.write("dat");
        // // This is workaround for creating vertex attribute for graph,
        // // This problem should be fixed by vertex translator or graph class
        // val vertexIds = new DistMemoryChunk[Long](places, () => {
        //     val id = MemoryChunk.make[Long](localState()._score.length());
        //     for (i in 0..(id.size() -1))
        //         id(i) = bc.LocSrcToOrg(i);
        //     return id;
        // });
        // g.setVertexAttribute[Long]("name", vertexIds);
        /// stopWatch.lap("Betweenness centrality calculation");
        return result;
    }
    
    private def start() {
        // determine sources
        if (lch()._numSource > 0) {
            // generate random sources
            val numSrc = lch()._numSource;
            val numAllVertices = lch()._numberOfVerticesInGraph;
            val srcArray = new Rail[Long](numAllVertices as Int, (i: Long) => i as Long);
            val r = new x10.util.Random(System.currentTimeMillis());
            for (i in 0..(srcArray.size -1)) {
                val index = r.nextLong(numAllVertices) as Int;
                val temp = srcArray(i);
                srcArray(i) = srcArray(index);
                srcArray(index) = temp;
            }
            for (i in 0..(numSrc - 1)) {
                computeForSource(srcArray(i as Int));
            }
        } else if (lch()._sources != null) {
            // use sources from given array           
            for (i in 0..(lch()._sources.size - 1)) {
                computeForSource(lch()._sources(i));
            }
        } else if (lch()._sourceRange.min >= 0 && lch()._sourceRange.max >= 0) {
            // use sources from given range
            for (i in lch()._sourceRange) {
                computeForSource(i);
            }
        }
    }
    
    private def computeForSource(src: Vertex) {
        val placeGroup = team.placeGroup();
        finish {
            for (p in placeGroup) { 
                at (p) async {
                    clear();
                    val locSrc = OrgToLocSrc(src);
                    var srcNeighbors: Long = 0;
                    if(isLocalVertex(src)) {
                        srcNeighbors = localGraph.adjacency(locSrc).size();
                    }
                    srcNeighbors = team.allreduce(srcNeighbors, Team.ADD);
                    if (srcNeighbors > 0L) {
                        // source has neighbor(s)
                        setLocalSource(src);
                        Runtime.x10rtBlockingProbe();
                        team.barrier();
                        
                        travelNonIncDist();
                        Runtime.x10rtBlockingProbe();
                        team.barrier();
                        
                        countSuccessor();	
                        Runtime.x10rtBlockingProbe();
                        team.barrier();
                        
                        addLeafNodeToUpdate();
                        Runtime.x10rtBlockingProbe();
                        team.barrier();
                        
                        backtracking(); 	
                        Runtime.x10rtBlockingProbe();
                        team.barrier();
                    }
                }
            }
        }
    }
    
    @Inline
    private def setLocalSource(v: Vertex) {
        lch()._currentSource() = v;
    }
    
    @Inline
    private def clear() {
        nextQ().clearAll();
        currentQ().clearAll();
        backtrackingCurrentQ().clearAll();
        backtrackingNextQ().clearAll();
        
        val ls = lch();
        ls._currentLevel() = 0L;
        val numLocalVertices = lch()._numLocalVertices;
        for (i in 0..(ls._numLocalVertices - 1)) {
            ls._distanceMap(i) = 0L;
            if (ls._predMap(i) != null) {
                ls._predMap(i).clear();
            }
            ls._successorCount(i) = 0;
            ls._pathCount(i) = 0;
            ls._numUpdate(i) = 0;
            ls._dependencies(i) = 0;
        }
        
        // ls._successorCount.clear(0, numLocalVertices);
        // ls._pathCount.clear(0, numLocalVertices);
        // ls._numUpdate.clear(0, numLocalVertices);
        // ls._dependencies.clear(0, numLocalVertices);
    }
    
    @Inline
    public def isLocalVertex(orgVertex: Vertex): Boolean {
        // val vertexPlace = ((1 << (lgc + lgr)) -1) & orgVertex;
        val vertexPlace = lch().v2s.r(orgVertex);
        if(vertexPlace == role )
            return true;
        return false;
    }
    
    /* Work around when optimizing. Parallel class will ca */
    private static @Inline def internalIter(range :LongRange, func :(Long, LongRange)=>void) {
        val size = range.max - range.min + 1;
        if(size == 0L) return ;
        val nthreads = Math.min(Runtime.NTHREADS as Long, size);
        val chunk_size = Math.max((size + nthreads - 1) / nthreads, 1L);
        finish for(i in 0..(nthreads-1)) {
            val idx = i;
            val i_start = range.min + i*chunk_size;
            val i_range = i_start..Math.min(range.max, i_start+chunk_size-1);
            async func(idx, i_range);
        }
    }
    
    public static @Inline def internalIter(range :LongRange, func :(Long)=>void) {
        val size = range.max - range.min + 1;
        if(size == 0L) return ;
        val nthreads = Math.min(Runtime.NTHREADS as Long, size);
        val chunk_size = Math.max((size + nthreads - 1) / nthreads, 1L);
        finish for(i in 0..(nthreads-1)) {
            val i_start = range.min + i*chunk_size;
            val i_range = i_start..Math.min(range.max, i_start+chunk_size-1);
            async for(ii in i_range) func(ii);
        }
    }
    
    @Inline
    public def OrgToLocSrc(v: Vertex) = lch().v2s(v);
    // public def OrgToLocSrc(v: Vertex) 
    // = (( v & (( 1 << lgr) -1)) << lgl) | (v >> (lgr + lgc));
    
    @Inline
    public def LocSrcToOrg(v: Vertex) = lch().s2v(v);
    // public def LocSrcToOrg(v: Vertex)
    // = ((((v & (( 1 << lgl) -1)) << lgc)| role) << lgr) | (v>> lgl);
    
    @Inline
    public def LocDstToOrg(v: Vertex) = lch().d2v(v);
    // public def LocDstToOrg(v: Vertex)
    // = ((((v & (( 1 << lgl) -1)) << lgc | (v >> lgl)) << lgr ) | 0);
    
    @Inline
    private def currentQ() = lch()._queues(lch()._qPointer());
    
    @Inline
    private def nextQ() = lch()._queues((lch()._qPointer() + 1n) & 1n);
    
    @Inline
    private def swapQ() { lch()._qPointer() = (lch()._qPointer() + 1n) & 1n; }
     
    @Inline
    private def backtrackingCurrentQ() = lch()._backtrackingQueues(lch()._backtrackingQPointer());
    
    @Inline
    private def backtrackingNextQ() = lch()._backtrackingQueues((lch()._backtrackingQPointer() + 1n) & 1n);
   
    @Inline
    private def swapUpdateScoreQ() { lch()._backtrackingQPointer() = (lch()._backtrackingQPointer() + 1n) & 1n; }
    
    @Inline
    private def getVertexPlace(orgVertex: Vertex): Place {
        return team.place(getVertexPlaceRole(orgVertex));
    }
    
    @Inline
    private def getVertexPlaceRole(orgVertex: Vertex): Int {
        val vertexPlaceId = ((1 << (lgc + lgr)) -1) & orgVertex;
        return vertexPlaceId as Int;
    }
         
    private def travelNonIncDist() {
        val bufSize = lch()._BUFFER_SIZE;
        val numTask = lch()._NUM_TASK;
        val predBuf = lch()._predBuf;
        val succBuf = lch()._succBuf;
        val sigmaBuf = lch()._sigmaBuf;
        
        val clearBuffer = (bufId: Int, pid: Int) => {
            predBuf(bufId)(pid).clear();
            succBuf(bufId)(pid).clear();
            sigmaBuf(bufId)(pid).clear();
        };
        val _flush = (bufId: Int, pid: Int) => {
            val preds = predBuf(bufId)(pid).toRail();
            val succs = succBuf(bufId)(pid).toRail();
            val predSigma = sigmaBuf(bufId)(pid).toRail();
            val count = preds.size;
            val p = team.place(pid);
            at (p)  {
                for(k in 0..(count - 1)) {
                    val lv = lch()._currentLevel();
                    visit(preds(k), succs(k), lv, predSigma(k));
                }
            }
            clearBuffer(bufId, pid);
        };
        val _flushAll = () => {
            finish for (i in 0..(numTask -1))
                async for (ii in 0..(team.size() -1)) {
                    if (predBuf(i)(ii).size() > 0)
                        _flush(i as Int, ii as Int);
                }
        };
        val _visitRemote = (bufId: Int, pid: Int, pred: Vertex, succ: Vertex, predSigma: Long) => {
            if (predBuf(bufId)(pid).size() >= bufSize) {  
                _flush(bufId, pid);
            } 
            predBuf(bufId)(pid).add(pred);
            succBuf(bufId)(pid).add(succ);
            sigmaBuf(bufId)(pid).add(predSigma);
        };
        // put source
        val src = lch()._currentSource();
        if (isLocalVertex(src)) {
            val locSrc = OrgToLocSrc(src);
            nextQ().set(locSrc);
            lch()._distanceMap(locSrc) = 0L;
            lch()._pathCount(locSrc) = 1L;
        }
        while(true) {
            swapQ();
            nextQ().clearAll();
            // Check wether there is a vertex on such a place
            val maxVertexCount = team.allreduce(
                    currentQ().setBitCount(),
                    Team.MAX);
            if (maxVertexCount == 0L)
                break;
            val traverse = (localSrc: Vertex, threadId: Int) => {           
                val neighbors = localGraph.adjacency(localSrc);
                val predDistance = lch()._distanceMap(localSrc);
                val predSigma = lch()._pathCount(localSrc);
                val orgSrc = LocSrcToOrg(localSrc);                        
                for(i in neighbors.range()) {
                    val orgDst = LocDstToOrg(neighbors(i));
                    if (isLocalVertex(orgDst))  {
                        visit(orgSrc, orgDst, predDistance, predSigma);
                    } else {
                        val bufId = threadId;
                        val p: Place = getVertexPlace(orgDst);
                        _visitRemote(bufId, team.role(p)(0), orgSrc, orgDst, predSigma);
                    }    
                }
            };
            currentQ().examine(traverse);
            _flushAll();
            team.barrier();
            lch()._currentLevel(lch()._currentLevel() + 1);
        }
    }
    
    public def visit(orgSrc: Long, orgDst: Long, predDistance: Long, predSigma: Long) {
        val localDst = OrgToLocSrc(orgDst);
        val d = predDistance + 1;
        val ls = lch();
        val f = () => {
            // var predMap: ArrayList[Long] = compare_and_swap_val[ArrayList[Long]](lch()._predMap, localDst, null, new ArrayList[Long]());    
            ls._predMap.atomicCAS(localDst, null, new ArrayList[Long]());
            val predMap = ls._predMap(localDst);
            // if (predMap == null) { 
            //     predMap = lch()._predMap(localDst);
            // }
            // add predecessor
            atomic predMap.add(orgSrc);
            // increase the number of geodesic paths
            // add_and_fetch[Long](ls._pathCount, localDst, predSigma);
            ls._pathCount.atomicAdd(localDst, predSigma);
        };
        if (ls._distanceMap.atomicCAS(localDst, 0L, d)) {
        // if (compare_and_swap(ls._distanceMap, localDst, 0L, d)) {
            // First visit
            nextQ().set(localDst);
        }         
        if (lch()._distanceMap(localDst) == d){
            // Another shortest path
            f();
        }
    }
    
    private def countSuccessor() {
        val bufSize = lch()._BUFFER_SIZE;
        val numTask = lch()._NUM_TASK;
        val predBuf = lch()._predBuf;
        val clearBuffer = (bufId: Int, pid: Int) => {
            predBuf(bufId)(pid).clear();
        };        
        val _flush = (bufId: Int, pid: Int) => {
            val preds = predBuf(bufId)(pid).toRail();
            val p = team.place(pid);
            at (p) {
                for(k in 0..(preds.size - 1)) {
                    val pred = preds(k);
                    val locPred = OrgToLocSrc(pred);
                    // add_and_fetch[Long](lch()._successorCount, locPred, 1L);
                    lch()._successorCount.atomicAdd(locPred, 1L);
                }
            }
            clearBuffer(bufId, pid);
        };
        val _flushAll = () => {
            finish for (i in 0..(numTask -1)) {
                val taskId = i;
                async for (ii in 0..(team.size() -1)) {
                    if (predBuf(i)(ii).size() > 0)
                        _flush(taskId as Int, ii as Int);
                }
            }
        };
        val addRemote = (bufId: Int, pid: Int, pred: Vertex) => {
            if (predBuf(bufId)(pid).size() >= bufSize) {  
                _flush(bufId, pid);
            }    
            predBuf(bufId)(pid).add(pred);
        };
        val examine = (threadId: Long, r: LongRange) => {
            for (i in r) {
                if (lch()._predMap(i) != null 
                        && lch()._predMap(i).size() > 0) {  
                    val sz = lch()._predMap(i).size();
                    for (k in 0..(sz -1)) {  
                        val pred = lch()._predMap(i)(k);
                        val locPred = OrgToLocSrc(pred);
                        if (isLocalVertex(pred))  {
                            // fetch_and_add[Long](lch()._successorCount, locPred, 1);
                            lch()._successorCount.atomicAdd(locPred, 1);
                        } else {
                            val targetRole = team.role(getVertexPlace(pred))(0);
                            addRemote(threadId as Int, targetRole, pred);
                        }    
                    }
                }   
            }
        }; 
        // iter(0..(lch()._numLocalVertices - 1), examine);
        internalIter(0..(lch()._numLocalVertices - 1), examine);

        _flushAll();
    }
    
    private def addLeafNodeToUpdate() {
        val checkNode = (threadId: Long, r: LongRange) => {
            for (i in r) {
                if (lch()._predMap(i) != null 
                        && lch()._predMap(i).size() > 0
                        && lch()._successorCount(i) == 0L) {
                    backtrackingNextQ().set(i);
                    // lch().debugLeafNode.getAndIncrement();
                } 
            }
        };
        internalIter(0..(lch()._numLocalVertices - 1), checkNode);
    }
    
    private def backtracking() {
        val bufSize = lch()._BUFFER_SIZE;
        val numTask = lch()._NUM_TASK;
        val predBuf = lch()._predBuf;
        val deltaBuf = lch()._deltaBuf;
        val sigmaBuf = lch()._sigmaBuf;
        val muBuf = lch()._muBuf;
        val clearBuffer = (bufId: Int, pid: Int) => {
            predBuf(bufId)(pid).clear();
            deltaBuf(bufId)(pid).clear();
            sigmaBuf(bufId)(pid).clear();
            muBuf(bufId)(pid).clear();
        };
        val _flush = (bufId: Int, pid: Int) => {
            val preds = predBuf(bufId)(pid).toRail();
            val delta = deltaBuf(bufId)(pid).toRail();
            val sigma = sigmaBuf(bufId)(pid).toRail();
            val mu = muBuf(bufId)(pid).toRail();
            val p = team.place(pid);
            at (p) {
                for(k in 0..(preds.size - 1)) {
                    val pred = preds(k);
                    calDependency(mu(k), delta(k), sigma(k), preds(k));
                }
            }
            clearBuffer(bufId, pid);
        };
        val _flushAll = () => {
            finish for (i in 0..(numTask -1))
                async for ( ii in 0..(team.size() -1)) {
                    if (predBuf(i)(ii).size() > 0)
                        _flush(i as Int, ii as Int);
                }
        };
        val calRemote = (bufId: Int, pid: Int, mu: Long, delta: Double, signma: Long, pred: Vertex) => {
            if (predBuf(bufId)(pid).size() >= bufSize) {  
                _flush(bufId, pid);
            } 
            muBuf(bufId)(pid).add(mu);
            deltaBuf(bufId)(pid).add(delta);
            sigmaBuf(bufId)(pid).add(signma);
            predBuf(bufId)(pid).add(pred);
        };
        while(true) {
            swapUpdateScoreQ();
            backtrackingNextQ().clearAll();
            team.barrier();
            // Check wether there is a vertex on such a place
            val maxVertexCount = team.allreduce(backtrackingCurrentQ().setBitCount(), Team.MAX);
            if (maxVertexCount == 0L)
                break;
            val traverse = (localSucc: Vertex, threadId: Int) => {           
                val predList = lch()._predMap(localSucc);
                val orgSucc = LocSrcToOrg(localSucc);
                if (predList != null && predList.size() > 0) {
                    val sz = predList.size();
                    for (i in 0..(sz -1)) {  
                        val pred = predList(i);
                        val w_sigma = lch()._pathCount(localSucc);
                        val w_delta = lch()._dependencies(localSucc);
                        val w_mu = lch()._distanceMap(localSucc);
                        if (isLocalVertex(pred))  {
                            calDependency(w_mu, w_delta, w_sigma, pred);
                        } else {
                            val bufId = threadId;
                            val pid = getVertexPlaceRole(pred);
                            calRemote(threadId, pid, w_mu, w_delta, w_sigma, pred);
                        }    
                    }
                }
            };
            backtrackingCurrentQ().examine(traverse);
            _flushAll();
            team.barrier();
        }
    }
    
    private def calDependency(w_mu: Long, w_delta: Double, w_sigma: Long, v: Vertex) {
        val inst = lch();
        val locPred = OrgToLocSrc(v);
        val l = inst._dependenciesLock(locPred);
        l.lock();
        // val numUpdates = add_and_fetch[Long](inst._numUpdate, locPred, 1L);
        val numUpdates = inst._numUpdate.atomicAdd(locPred, 1L);
        val sigma = inst._pathCount(locPred) as Double;
        
        var dep: Double = 0;
        if (lch()._linearScale) {
            dep = inst._dependencies(locPred) + (inst._distanceMap(locPred) as Double / w_mu) * (sigma / w_sigma as Double) * (1 + w_delta);
        } else {
            dep = inst._dependencies(locPred) + ((sigma as Double)/ w_sigma ) * (1 + w_delta);
        }
        inst._dependencies(locPred) = dep;
       
        if(numUpdates == inst._successorCount(locPred)) {
            if (LocSrcToOrg(locPred) != inst._currentSource()) {
                inst._score(locPred) += dep;
            }
            backtrackingNextQ().set(locPred);
        }
       l.unlock();
    }
}
