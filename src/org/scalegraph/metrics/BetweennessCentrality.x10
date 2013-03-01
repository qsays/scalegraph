package org.scalegraph.metrics;

import org.scalegraph.util.tuple.*;
import org.scalegraph.fileread.DistributedReader;
import x10.util.Team;
import org.scalegraph.graph.Graph;
import org.scalegraph.concurrent.Dist2D;
import org.scalegraph.concurrent.Parallel;
import org.scalegraph.util.MathAppend;
import org.scalegraph.graph.DistSparseMatrix;
import org.scalegraph.util.DistMemoryChunk;
import org.scalegraph.util.MemoryChunk;
import x10.io.SerialData;
import x10.compiler.Inline;
import org.scalegraph.graph.SparseMatrix;
import x10.array.RemoteArray;
import x10.util.concurrent.AtomicLong;
import x10.compiler.Ifndef;
import x10.util.IndexedMemoryChunk;
import x10.util.concurrent.Lock;
import x10.util.ArrayList;
import x10.util.GrowableIndexedMemoryChunk;
import x10.compiler.Volatile;

public type Vertex = Long;
public type Distance = Long;

public class BetweennessCentrality implements x10.io.CustomSerialization {
    
    private val team: Team;
    private val lgl: Int;
    private val lgc: Int;
    private val lgr: Int;
    private val role: Int;
    private val source: Cell[Vertex];
    private val currentLevel: Cell[Long];
    private val localGraph: SparseMatrix;
    
    protected static struct Buffer {
        val _pred: Array[Long];
        val _succ: Array[Long];
        val count: Cell[Long];
        
        def this(sz: Long) {
            _pred = new Array[Long](IndexedMemoryChunk.allocateZeroed[Long](sz, 
                    64,
                    false));
            count = new Cell[Long](0);
            _succ = new Array[Long](IndexedMemoryChunk.allocateZeroed[Long](sz, 
                    64,
                    false));
        }
    }
    
    protected static struct BufferAll {
        val item: Array[Buffer];
        
        def this(p: Int, sz: Long) {
            item = new Array[Buffer](IndexedMemoryChunk.allocateZeroed[Buffer](p, 
                    64,
                    false));
            
            for (i in (0..(p-1)))
                item(i) = new Buffer(sz);
        }
    }
    
    public static class LocalState {

        val _distSparseMatrix: DistSparseMatrix;
        val _source: Cell[Vertex];
        // val _globalDistance: DistMemoryChunk[Distance];
        val _queues: IndexedMemoryChunk[Bitmap];
        val _qPointer: Cell[Int];
        val _distanceMap: IndexedMemoryChunk[Long];
        val _visitMap: Bitmap;
        val _currentLevel: Cell[Long];
        val _bf: Array[BufferAll];
        val _numLocalVertices: Long;
        // Buffer for bfs
        val _BUFFER_SLOT: Int;
        val _BUFFER_SIZE: Int;
        static val _ALIGN = 64;
        static val _CONGRUENT = false;
        
        // Bfs stuff
        val _predMap: IndexedMemoryChunk[ArrayList[Long]];
        val _updatePredBuf: IndexedMemoryChunk[ArrayList[Long]];
        val _successorCount: IndexedMemoryChunk[AtomicLong];
        val _pathCount: IndexedMemoryChunk[Long];
        val _dependency: IndexedMemoryChunk[Double];
        
        val _isInFloodAll: Cell[Boolean];
        
        // Back tracking stuff
        val _updateScoreQueues: IndexedMemoryChunk[Bitmap];
        val _updateScoreQPointer: Cell[Int];
        val _numUpdate: IndexedMemoryChunk[Int];
        val _succLoc: Lock = new Lock();
        val _distanceLock: Lock = new Lock();
        
        // Debuging
        val numVertexVisit: AtomicLong = new AtomicLong(0);
        val numExamine: AtomicLong = new AtomicLong(0);
        val numAddPred: AtomicLong = new AtomicLong(0);
        
        protected def this(dsm: DistSparseMatrix,
                           src: Vertex,
                           globDist: DistMemoryChunk[Distance],
                           buffSize: Int) {
            val t = dsm.dist().allTeam();
            _distSparseMatrix = dsm;
            _source = new Cell[Vertex](src);
            // this._globalDistance = globDist;
            _queues = IndexedMemoryChunk.allocateUninitialized[Bitmap](2,
                            _ALIGN,
                            _CONGRUENT);
            
            // Create queues
            _numLocalVertices = dsm.ids().maxLocalId;
            _queues(0) = new Bitmap(_numLocalVertices);
            _queues(1) = new Bitmap(_numLocalVertices);
            _visitMap = new Bitmap(_numLocalVertices);
            _qPointer = new Cell[Int](0);
            
            _BUFFER_SIZE = buffSize;
            _currentLevel = new Cell[Long](0);
            
            _distanceMap = IndexedMemoryChunk.allocateZeroed[Long](
                    _numLocalVertices,
                    _ALIGN,
                    _CONGRUENT);
            
            _predMap =IndexedMemoryChunk.allocateUninitialized[ArrayList[Long]](
                    _numLocalVertices,
                    _ALIGN,
                    _CONGRUENT);
            _successorCount = IndexedMemoryChunk.allocateUninitialized[AtomicLong](
                    _numLocalVertices,
                    _ALIGN,
                    _CONGRUENT);
            _pathCount = IndexedMemoryChunk.allocateZeroed[Long](_numLocalVertices, 64, false);
            _dependency = IndexedMemoryChunk.allocateZeroed[Double](_numLocalVertices, 64, false);
            _updatePredBuf = IndexedMemoryChunk.allocateUninitialized[ArrayList[Long]](t.size(), 64, false);
            
            for (i in 0..(_updatePredBuf.length() - 1)) {
                _updatePredBuf(i) = new ArrayList[Long]();;
            }
            
            _isInFloodAll = new Cell[Boolean](false);

            // Create queue for updating score
            _updateScoreQueues = IndexedMemoryChunk.allocateUninitialized[Bitmap](2, _ALIGN, false);
            _updateScoreQueues(0) = new Bitmap(_numLocalVertices);
            _updateScoreQueues(1) = new Bitmap(_numLocalVertices);
            _updateScoreQPointer = new Cell[Int](0);
            _numUpdate = IndexedMemoryChunk.allocateZeroed[Int](_numLocalVertices, _ALIGN, false);
            
            // Init loop
            for (i in 0..(_numLocalVertices - 1)) {
                _distanceMap(i) = 0L;
                _predMap(i) = null;
                _successorCount(i) = new AtomicLong(0);;
                _pathCount(i) = 0L;
                _numUpdate(i) = 0;
                _dependency(i) = 0D;
            }
            
            _BUFFER_SLOT = Runtime.NTHREADS;
            this._bf = new Array[BufferAll](_BUFFER_SLOT);           
            for (i in 0..(_BUFFER_SLOT - 1)) {
                _bf(i) = new BufferAll(t.size(), _BUFFER_SIZE);
            }
        }
    }
    
    public val lch:PlaceLocalHandle[LocalState];
    
    private def this(lch_:PlaceLocalHandle[LocalState]) {
        
        // Set local state
        lch  = lch_;
        
        // Init fields
        val dsm = lch_()._distSparseMatrix;
        
        team = 	dsm.dist().allTeam();
        lgl = dsm.ids().lgl;
        lgc = dsm.ids().lgc;
        lgr = dsm.ids().lgr;
        role = team.getRole(here);
        localGraph = dsm();
        source = lch_()._source();
        currentLevel = lch_()._currentLevel;
    }
    
    public def this (serialData: SerialData) {
        this(serialData.data as PlaceLocalHandle[LocalState]);
    }
    
    public def serialize(): SerialData {
        return new SerialData(lch, null);
    }
    
    public static def run(g: Graph) {
        val team = g.team();
        val places = team.placeGroup();
        val csr = g.constructDistSparseMatrix(
                Dist2D.make1D(team, Dist2D.DISTRIBUTE_COLUMNS),
                true,
                true);

        // Create distance storage for each vertex
        val globalDistance = new DistMemoryChunk[Distance](places,
                () => {
            val ids = csr.ids();
            val numLocalVertices = ids.maxLocalId;
            val distance = new MemoryChunk[Distance](numLocalVertices,
                    64);
            
            for (i in distance.range())
                distance(i) = 0L;
            
            return distance;
        });
        
        // Create bc local state
        val lsBfsBufferSize = (1 << 15);
        val firstSource = 0;
        val localState = PlaceLocalHandle.make[LocalState](places, 
                () => { 
            return (new LocalState(csr,
                    					firstSource,
                    					globalDistance,
                    					lsBfsBufferSize));
        });
        
        val visitor = new BetweennessCentrality(localState);
        visitor.internalRun();
    }
    
    private def internalRun() {
        var time: Long = System.currentTimeMillis();
        val placeGroup = team.placeGroup();
        finish {
            for (p in placeGroup) {
                at (p) async {
                    travelNonIncDist();     team.barrier(role);
                    countSuccessor();	      team.barrier(role);
                    addLeafNodeToUpdate();   team.barrier(role);
                    val c = team.allreduce(role, updateScoreNextQ().setBitCount(), Team.ADD);team.barrier(role);
                    updateScore(); 			team.barrier(role);
                    
                    lch().numVertexVisit.set(team.allreduce(role, lch().numVertexVisit.longValue(), Team.ADD));
                    lch().numExamine.set(team.allreduce(role, lch().numExamine.longValue(), Team.ADD));
                    
                    val d = team.allreduce(role, lch().numAddPred.longValue(), Team.ADD);
                        
                    if (here.id == 0) {
                        Console.OUT.println("Add Pred: " + d);
                        Console.OUT.println("Sum set: " + c);    
                    }
                }
            }
        }
        time = System.currentTimeMillis() - time;
        print();
        Console.OUT.println("BC time: " + time);
        Console.OUT.println("Num visit: " + lch().numVertexVisit.longValue());
        Console.OUT.println("Num examine: " + lch().numExamine.longValue());
    }
    

    
    public def setSource(v: Vertex) {
        source() = v;
        lch()._source() = v;
    }
    
    
    public def isLocalVertex(orgVertex: Vertex): Boolean {
        val vertexPlace = ((1 << (lgc + lgr)) -1) & orgVertex;
        if(vertexPlace == role as Long)
            return true;
        return false;
    }
    
    public def OrgToLocSrc(v: Vertex) 
    	// = (( v & (( 1 << lgr) -1)) << lgl) | (v >> (lgr + lgc));
    // = (v >> lgc);
    = (( v & (( 1 << lgr) -1)) << lgl) | (v >> (lgr + lgc));
    
    public def LocSrcToOrg(v: Vertex)
    	// = ((((v & (( 1 << lgl) -1)) << lgc)| role) << lgr) | (v>> lgl);
    // = (((v & (( 1 << lgl) -1)) << lgc)| role);
    = ((((v & (( 1 << lgl) -1)) << lgc)| role) << lgr) | (v>> lgl);
    
    public def LocDstToOrg(v: Vertex)
    	// = (((v & ((1 << lgl) - 1)) << lgc) | (v >> lgl));
    = ((((v & (( 1 << lgl) -1)) << lgc | (v >> lgl)) << lgr ) | 0);
    
    private def currentQ() = lch()._queues(lch()._qPointer());
    
    private def nextQ() = lch()._queues((lch()._qPointer() + 1) & 1);
    
     private def swapQ() {
        lch()._qPointer() = (lch()._qPointer() + 1) & 1;
    }
     
    private def updateScoreCurrentQ() = lch()._updateScoreQueues(lch()._updateScoreQPointer());
    
    private def updateScoreNextQ() = lch()._updateScoreQueues((lch()._updateScoreQPointer() + 1) & 1);
   
    private def swapUpdateScoreQ() {
        lch()._updateScoreQPointer() = (lch()._updateScoreQPointer() + 1) & 1;
    }
    
    public def getVertexPlace(orgVertex: Vertex): Place {
        val vertexPlaceId = ((1 << (lgc + lgr)) -1) & orgVertex;
        return team.getPlace(vertexPlaceId as Int);
    }
    
    private def allocNewBuffer(slotId: Int, pid: Int) {  
        lch()._bf(slotId).item(pid) = new Buffer(lch()._BUFFER_SIZE);
    }
    
    private def countSuccessor() {
        if (here.id == 0)
            Console.OUT.println("Count Successor");
        
        val bufSize = (1 << 8);
        val numTask = Runtime.NTHREADS;
        val predBuf = new Array[Array[ArrayList[Vertex]]](numTask,
                (int) => new Array[ArrayList[Vertex]](team.size(),
                        (int) => new ArrayList[Vertex](bufSize)));
        
        val clearBuffer = (bufId: Int, pid: Int) => {
            // predBuf(bufId)(pid).clear();
            predBuf(bufId)(pid) = new ArrayList[Vertex](bufSize);
        };
        
        val _flood = (bufId: Int, pid: Int) => {
            val preds = predBuf(bufId)(pid).toArray();
            val p = team.getPlace(pid);
            at (p) {
                for(k in 0..(preds.size - 1)) {
                    val pred = preds(k);
                    val locPred = OrgToLocSrc(pred);
                    lch()._successorCount(locPred).incrementAndGet();
                    lch().numAddPred.incrementAndGet();
                }
            }
            clearBuffer(bufId, pid);
        };
        
        val _floodAll = () => {
            finish for (i in 0..(numTask -1)) {
                val taskId = i;
                for (ii in 0..(team.size() -1)) {
                    if (predBuf(i)(ii).size() > 0)
                        _flood(taskId, ii);
                }
            }
        };
        
        val addRemote = (bufId: Int, pid: Int, pred: Vertex) => {
            if (predBuf(bufId)(pid).size() >= bufSize) {  
                _flood(bufId, pid);
            }    
            predBuf(bufId)(pid).add(pred);
        };
        
        val examine = (i: Long, threadId: Int) => {
            if (lch()._predMap(i) != null 
                    && lch()._predMap(i).size() > 0) {  
                val sz = lch()._predMap(i).size();
                for (k in 0..(sz -1)) {  
                    val pred = lch()._predMap(i)(k);
                    val locPred = OrgToLocSrc(pred);
                    
                    if (isLocalVertex(pred))  {
                        lch()._successorCount(locPred).incrementAndGet();
                        lch().numAddPred.incrementAndGet();
                    } else {
                        val targetRole = team.getRole(getVertexPlace(pred));
                        addRemote(threadId, targetRole, pred);
                    }    
                }
            }   
        }; 
        Bitmap.iter(0..(lch()._numLocalVertices - 1), examine);
        _floodAll();
    }
    
    private def travelNonIncDist() {    
        // Putsource
        if (isLocalVertex(source())) {
            val locSrc = OrgToLocSrc(source());
            nextQ().set(locSrc);
            lch()._visitMap.set(locSrc);
            lch()._distanceMap(locSrc) = 0;
        }
        team.barrier(role);
        
        if (here.id == 0)
        	Console.OUT.println("Start BFS");
        
        // Start traveling
        while(true) {
            if(here.id == 0)
                Console.OUT.println("``````````(" + currentLevel() + ")````````````");
            swapQ();
            nextQ().clearAll();
            team.barrier(role);

            // Check wether vertex is available
            val maxVertexCount = team.allreduce(role,
                    currentQ().setBitCount(),
                    Team.MAX);
            if (maxVertexCount == 0L)
                break;
            
            val traverse = (localSrc: Vertex, threadId: Int) => {           
                val neighbors = localGraph.adjacency(localSrc);
                val predDistance = lch()._distanceMap(localSrc);
                val orgSrc = LocSrcToOrg(localSrc);                               
                for(i in neighbors.range()) {
                    lch().numExamine.incrementAndGet();
                    val orgDst = LocDstToOrg(neighbors(i));
                    if (isLocalVertex(orgDst))  {
                        visit(orgSrc, orgDst, predDistance);
                    } else {
                        val bufId = threadId;
                        val p: Place = getVertexPlace(orgDst);
                        visitRemote(bufId, p, orgSrc, orgDst, predDistance);
                    }    
                }
            };
            currentQ().examine(traverse);
            floodAll();
            team.barrier(role);
            currentLevel(currentLevel() + 1);
        }
    }
    
    public atomic def visit(orgSrc: Long, orgDst: Long, predDistance: Long) {
        val localDst = OrgToLocSrc(orgDst);
        val d = predDistance + 1;
        val f = () => {
            atomic {   
                var predMap: ArrayList[Long] = lch()._predMap(localDst);
                if (predMap == null) {
                    lch()._predMap(localDst)  = new ArrayList[Long]();;
                    predMap = lch()._predMap(localDst);
                }
                // Add predecessor
                predMap.add(orgSrc);
                
                // Increase path count
                lch()._pathCount(localDst) = lch()._pathCount(localDst) + 1;
                lch().numVertexVisit.incrementAndGet();
            }
        };
        
        // val f2 = () => {
        //     atomic {   
        //         var predMap: ArrayList[Long] = lch()._predMap(localDst);
        //         predMap.add(orgSrc);
        //         
        //         // Increase path count
        //         lch()._pathCount(localDst) = lch()._pathCount(localDst) + 1;
        //         lch().numVertexVisit.incrementAndGet();
        //     }
        // };
        // Console.OUT.println(orgSrc + " - " + orgDst);
        if (lch()._visitMap.isNotSetAndMark(localDst)) {
            // First visit
            nextQ().set(localDst);
            lch()._distanceLock.lock();
            lch()._distanceMap(localDst) = d;
            lch()._distanceLock.unlock();
            // f();

        } 
        
        if (lch()._distanceMap(localDst) == d){
            // Another shortest path
            f();
        }
    }
    
    private def flood(bufId: Int, p: Place) {
        val targetRole = team.getRole(p);
        val count = lch()._bf(bufId).item(targetRole).count();
        val succ = new RemoteArray[Long](lch()._bf(bufId).item(targetRole)._succ);
        val preds = new RemoteArray[Long](lch()._bf(bufId).item(targetRole)._pred);
        val level = lch()._currentLevel();
            at (p) {
                val num = count as Int;
                val t_s = new Array[Long](IndexedMemoryChunk.allocateZeroed[Long](
                        num, 
                        lch()._ALIGN,
                        lch()._CONGRUENT));
                val t_p = new Array[Long](IndexedMemoryChunk.allocateZeroed[Long](
                        num, 
                        lch()._ALIGN,
                        lch()._CONGRUENT));
                
                finish {
                    Array.asyncCopy(succ, 0, t_s, 0, num);
                    Array.asyncCopy(preds, 0, t_p, 0, num);
                }
                
                for (var t: Int = 0; t < num; ++t) {
                    visit(t_p(t), t_s(t), level);
                } 
            }
            lch()._bf(bufId).item(targetRole).count() = 0;
            allocNewBuffer(bufId, targetRole);
    }
    
    public def floodAll() {        
        finish  for(i in 0..(lch()._BUFFER_SLOT - 1)) {
             for (k in 0..(team.size() - 1)) {
                val p = team.getPlace(k);
                if (!p.equals(here)){
                    flood(i, p);
                }
            }
        }
    }
    
    private def visitRemote(bufId: Int, p: Place, pred: Vertex, v: Vertex, predDist: Long) {
        val targetRole = team.getRole(p);
        var count: Int = lch()._bf(bufId).item(targetRole).count() as Int;

        if (count == lch()._BUFFER_SIZE) {
            flood(bufId, p);
            lch()._bf(bufId).item(targetRole).count() = 0;
            count = 0;
        }
        lch()._bf(bufId).item(targetRole)._succ(count) = v;
        lch()._bf(bufId).item(targetRole)._pred(count) = pred;
        lch()._bf(bufId).item(targetRole).count() = count + 1;
    }
    
    // public def clear() {
    //     val func = () => {
    //         lch()._queues(0).clearAll();
    //         lch()._queues(1).clearAll();
    //         
    //         for (i in lch()._distanceMap.range())
    //             lch()._distanceMap(i) = 0L;
    //     };
    //     
    //     finish for (p in team.placeGroup())
    //         if (p == here) 
    //             async func();
    //         else 
    //             at (p) func();
    // }

    public def del() {
        // TODO: clear all reference
    }
    
    public def addLeafNodeToUpdate() {
        val checkNode = (i: Long, threadId: Int) => {
            if (lch()._predMap(i) != null 
                    && lch()._predMap(i).size() > 0
                    && lch()._successorCount(i).longValue() == 0L) {
                updateScoreNextQ().set(i);
            } 
        };
        
        Bitmap.iter(0..(lch()._numLocalVertices - 1), checkNode);
    }
    
    public def updateScore() {
        
        val bufSize = (1 << 8);
        val numTask = Runtime.NTHREADS;
        val predBuf = new Array[Array[ArrayList[Vertex]]](numTask,
                (int) => new Array[ArrayList[Vertex]](team.size(),
                        (int) => new ArrayList[Vertex](bufSize)));
        val thetaBuf = new Array[Array[ArrayList[Double]]](numTask,
                (int) => new Array[ArrayList[Double]](team.size(),
                        (int) => new ArrayList[Double](bufSize)));
        val sigmaBuf = new Array[Array[ArrayList[Long]]](numTask,
                (int) => new Array[ArrayList[Long]](team.size(),
                        (int) => new ArrayList[Long](bufSize)));
        
        val clearBuffer = (bufId: Int, pid: Int) => {
            predBuf(bufId)(pid).clear();
            thetaBuf(bufId)(pid).clear();
            sigmaBuf(bufId)(pid).clear();
        };
        
        val _flood = (bufId: Int, pid: Int) => {
            val preds = predBuf(bufId)(pid).toArray();
            val theta = thetaBuf(bufId)(pid).toArray();
            val sigma = sigmaBuf(bufId)(pid).toArray();
            val p = team.getPlace(pid);
            at (p) {
                for(k in 0..(preds.size - 1)) {
                    val pred = preds(k);
                    calDependency(theta(k), sigma(k), preds(k));
                }
            }
            clearBuffer(bufId, pid);
        };
        
        val _floodAll = () => {
            finish for (i in 0..(numTask -1))
                async for ( ii in 0..(team.size() -1)) {
                    if (predBuf(i)(ii).size() > 0)
                        _flood(i, ii);
                }
        };
        
        val calRemote = (bufId: Int,pid: Int, theta: Double, signma: Long, pred: Vertex) => {
            if (predBuf(bufId)(pid).size() >= bufSize) {  
                _flood(bufId, pid);
            } 
            thetaBuf(bufId)(pid).add(theta);
            sigmaBuf(bufId)(pid).add(signma);
            predBuf(bufId)(pid).add(pred);
        };
        
        if (here.id == 0) {
            Console.OUT.println("Update Score");
        	// Console.OUT.println("Sum setcount: " + c);
        }
        Console.OUT.println(here.id + ": Set count: " + updateScoreNextQ().setBitCount());
        team.barrier(role);
        
        // Start traveling
        while(true) {
            swapUpdateScoreQ();
            updateScoreNextQ().clearAll();
            team.barrier(role);

            // Check wether vertex is available
            val maxVertexCount = team.allreduce(role, updateScoreCurrentQ().setBitCount(), Team.MAX);
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
                        val w_theta = lch()._dependency(localSucc);
                        if (isLocalVertex(pred))  {
                            calDependency(w_theta, w_sigma, pred);
                        } else {
                            val bufId = threadId;
                            val p: Place = getVertexPlace(pred);
                            val pid = team.getRole(p);
                            // at (p) calDependency(w_theta, w_sigma, pred);
                            calRemote(threadId, pid, w_theta, w_sigma, pred);
                        }    
                    }
                }
            };
            updateScoreCurrentQ().examine(traverse);
            team.barrier(role);
        }
    }
    
    public atomic def calDependency(w_theta: Double, w_sigma: Long, v: Vertex) {
            val locSucc = OrgToLocSrc(v);
             lch()._numUpdate(locSucc) = lch()._numUpdate(locSucc) + 1;
            
            lch()._dependency(locSucc) = lch()._dependency(locSucc) 
            + (lch()._pathCount(locSucc) as Double / w_sigma) * (1 + w_theta);
            
            if(lch()._numUpdate(locSucc) as Long == lch()._successorCount(locSucc).longValue()) {
                updateScoreNextQ().set(locSucc);
            }
            if(lch()._successorCount(locSucc).longValue() > 0 && lch()._numUpdate(locSucc) as Long > lch()._successorCount(locSucc).longValue()) {
                    Console.OUT.println("============="+ "Cal dep: " + v 
                            + " num up: " + lch()._numUpdate(locSucc) 
                            + " , succ: " + lch()._successorCount(locSucc) +"============");
            }
        
    }
    
    //// Debugging Part 
    public def print() {
        val places = team.placeGroup();
        
        for (p in places) {
            at (p) {
                val dat = lch()._predMap;
                for (i in 0..(dat.length() - 1)) {
                    var succCount: Long = lch()._successorCount(i).longValue();
                    var predCount: Long = -1;
                    val path = lch()._pathCount(i);
                    
                    if (dat(i) != null)
                        predCount = dat(i).size();
                    
                    // if (succCount > 0 || predCount > 0)
                    //     Console.OUT.println(LocSrcToOrg(i) + " -> " + dat(i) 
                    //             + " : " + succCount
                    //             + " : " + path);
                    // if (succCount > 0 || predCount > 0)
                    //     Console.OUT.println(LocSrcToOrg(i) + " -> " + predCount 
                    //             + " : " + succCount
                    //             + " : " + path);
                    // if (lch()._dependency(i) > 0D)
                    // 	Console.OUT.println(LocSrcToOrg(i) + " -> " +  lch()._dependency(i));
                    // if (predCount != -1L)
                    // 	Console.OUT.println(LocSrcToOrg(i) + " " + succCount);
                }
            }
        }
    }
    
    
    //////////////////////////////////////////

	
	public static struct Bitmap {
	    protected val bitLength: Long;
	    protected val data: IndexedMemoryChunk[Long];
	    protected val bitPerWord = 64;
	    protected val setCount: AtomicLong;
	    protected val opLock = new Lock();
	    
	    public def this(length: Long) {
	        bitLength = length;
	        val allocSize = (bitLength >> 6) + 1; // div by 64
	        data = IndexedMemoryChunk.allocateZeroed[Long](allocSize, 64, false); 
	        
	        // Clear bits
	        for (i in 0..(data.length() - 1))	            
	           data(i) = 0L;
	        setCount = new AtomicLong(0);
	    }
	    
	    public atomic def set(bit: Long) {
	        val bitOffset = bit & ((1L << 6) -1);
	        val wordOffset = bit >> 6;
	        val mask = (1L << (bitOffset as Int));
	        
	        @Ifndef("NO_BOUNDS_CHECKS") {
	            if(bit < 0 || bit >= bitLength)
	                throw new ArrayIndexOutOfBoundsException("bit (" + bit + ") not contained in BitMap");
	        }
	        // If it is already set
	        if (((data(wordOffset) as ULong) & mask as ULong) > 0UL)
	            throw new Exception("Bit (" + bit + ") is already set");
 	       
	        opLock.lock();
	        // data.atomicOr(wordOffset, mask);
	        data(wordOffset) = data(wordOffset) | mask; 
	        opLock.unlock();
	        setCount.incrementAndGet();
	    }
	    
	    public atomic def clear(bit: Long) {
	        val bitOffset = bit & ((1L << 6) -1);
	        val wordOffset = bit >> 6;
	        val mask = ~(1L << (bitOffset as Int));
	        
	        @Ifndef("NO_BOUNDS_CHECKS") {
	            if(bit < 0 || bit >= bitLength)
	                throw new ArrayIndexOutOfBoundsException("bit (" + bit + ") not contained in BitMap");
	        }
	        // If it is already clear
	        if ((data(wordOffset) | mask) == 0L)
	            throw new Exception("Bit is already cleared");
	        
	        opLock.lock();
	        // data.atomicAnd(wordOffset, mask);
	        data(wordOffset) = data(wordOffset) & mask;
	        opLock.unlock();
	        setCount.decrementAndGet();
	    }
	    
	    public atomic def isNotSetAndMark(bit: Long): Boolean {
	        if (isNotSet(bit)) {
	            set(bit);
	            return true;
	        } else {
	            return false;
	        }
	    }
	    
	    public def isSet(bit: Long) = !isNotSet(bit);
	    
	    public def isNotSet(bit: Long): Boolean {
	        val bitOffset = bit & ((1L << 6) -1);
	        val wordOffset = bit >> 6;
	        val mask = (1L << (bitOffset as Int));
	       
	        return (data(wordOffset) as ULong & mask as ULong) == 0UL;
	    }
	    
	    public def examine(callback: (i: Long, threadId: Int) => void) {
	        val f = (w: Long, threadId: Int) => {
	            val word = data(w);
	            var mask: Long = 0x1;
	            var callCount: Long = 0;
	            
	            if (word == 0L)
	                return;
	            
	            for (var l: Long = 0; l < bitPerWord; ++l) { 
	                mask = 1L << (l as Int);
	                
	                if (((word as ULong) & (mask as ULong)) > 0UL) {
	                    val bitPos = w * bitPerWord + l;
	                    
	                    if (bitPos >= bitLength)
	                        break;
	                    
	                    callback(bitPos , threadId);
	                } 
	            }
	        };
	        
	        if (setCount.longValue() > 0)
	            iter(0..(data.length() as Long - 1), f);
	    }
	    
	    public static @Inline def iter(range :LongRange, func :(Long, Int) => void) {
	        val size = range.max - range.min + 1;
	        
	        if (size == 0L)
	            return ;
	        
	        val nthreads = Math.min(Runtime.NTHREADS as Long, size);
	        val chunk_size = Math.max((size + nthreads - 1) / nthreads, 1L);
	        
	        finish for(i in 0..(nthreads-1)) {
	            val i_start = range.min + i * chunk_size;
	            val i_range = i_start..Math.min(range.max, i_start+chunk_size-1);
	            val threadId = i as Int;
	            async for(ii in i_range) {
	                func(ii, threadId);
	            }
	        }
	    }
	    
	    public def clearAll() {   
	        // Parallel.iter(0..(data.length() as Long - 1), (i: Long) => { data(i) = 0L;});
	        for (i in 0..(data.length() - 1))	            
	            data(i) = 0L;
	        setCount.set(0L);
	    }
	    
	    public def setBitCount() = setCount.longValue();
	}
}