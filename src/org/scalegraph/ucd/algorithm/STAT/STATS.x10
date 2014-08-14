package org.scalegraph.ucd.algorithm.STAT;
import x10.compiler.Ifdef;
import org.scalegraph.xpregel.XPregelGraph;
import org.scalegraph.xpregel.VertexContext;
import org.scalegraph.util.MemoryChunk;
import org.scalegraph.xpregel.Vertex;
import org.scalegraph.util.MathAppend;
import x10.util.List;
import org.scalegraph.io.NamedDistData;
import org.scalegraph.io.CSV;
import org.scalegraph.test.AlgorithmTest;
import org.scalegraph.Config;
import org.scalegraph.graph.Graph;

public class STATS extends AlgorithmTest{
	var edgesTotal:Long;
	var lccAverage: Long;
	var counter: Int;
	var verticesTotal: Long;
val LCC = new GlobalRef[Cell[Long]](new Cell[Long](0l));
	//var vertex :VertexContext[Long, Double, Long, Long];

	public def perform_STATS(g: XPregelGraph[Long, Double]){
              
val sw = Config.get().stopWatch();
		g.updateInEdge();
                sw.lap("Update In Edge");
		@Ifdef("PROF_XP") { Config.get().dumpProfXPregel("Update In Edge:"); }

		 val edgesTotalRef = new GlobalRef[Cell[Long]](new Cell[Long](0l));//Global ref to object in cell.
		 val verticesTotalRef = new GlobalRef[Cell[Long]](new Cell[Long](0l));
		 g.iterate[Long,Long]((vertex :VertexContext[Long, Double, Long, Long], messages :MemoryChunk[Long]) => {

vertex.aggregate(vertex.outEdgesId().size());//aggregate of all the edges.

		   if(here.id == 0){
		   verticesTotalRef()() = vertex.numberOfVertices();
		   }

		 //vertex.output(vertex.outEdgesId().size());// adding data to the buffer.

		 },
		(values :MemoryChunk[Long]) => MathAppend.sum(values),
		((superstep :Int, aggVal :Long) => {
		    if(here.id == 0) {
		        edgesTotalRef()() = aggVal; // saving the aggregate value after sum into the global ref variable as it can be used anywhere.
		    }
		    return true;
		}));

		edgesTotal = edgesTotalRef()();
		verticesTotal = verticesTotalRef()();

		val avgLCC = (calculateLCC(g)/verticesTotal);

		Console.OUT.println("Number of vertices = "+verticesTotal+" Number of edges = "+edgesTotal+" Average Lcc = "+avgLCC);
		 //val degree = g.stealOutput[Long]();//stealing data from the buffer.
sw.lap("STAT Main Iterate (debug)");
		@Ifdef("PROF_XP") { Config.get().dumpProfXPregel("STAT Main Iterate (debug):"); }

	}

	private def calculateLCC(g: XPregelGraph[Long, Double]){
val sw = Config.get().stopWatch();

g.iterate[MemoryChunk[Long],Long]((ctx :VertexContext[Long, Double, MemoryChunk[Long], Long], messages :MemoryChunk[MemoryChunk[Long]]) => {

		val number_of_neighbour = ctx.outEdgesId().size();

        if(number_of_neighbour > 1){

        // to send message we need to have 2 steps.
            if(ctx.superstep() == 0) {
                ctx.sendMessageToAllNeighbors(ctx.outEdges().get1());
            }
            else if(ctx.superstep() == 1) {

                for(i in messages.range()) {

                    val neighbours = messages(i);                   
  // while(neighbours.iterator().hasNext()){ 
                        	//val node = neighbours.iterator().next();
                        	val nn = ctx.outEdgesId();
                        	for(j in nn.range()){
                        		for (k in neighbours.range()){
                        		if(nn(j) == neighbours(k)){
                        			counter++;
                        		}
                        		}
                        	}                        
                    }
//}
                    //val number_of_neighbour = neighbourRef()();
                    LCC()() += (counter/((number_of_neighbour*(number_of_neighbour-1))/2));
                }
        }
        else{
            
        }
        },
        (values :MemoryChunk[Long]) => MathAppend.sum(values),
                ((superstep :Int, aggVal :Long) => {
                    return superstep == 1;
                }));
sw.lap("STAT LCC Iterate (LCC)");
                @Ifdef("PROF_XP") { Config.get().dumpProfXPregel("STAT LCC Iterate (LCC):"); }

		return LCC()();
	
	//if the destination of the edge is in the set of the neighbour then increase counter.
		// formula is number of edges connected i.e. counter divide by no of pairs that can be formed within the neighbour
		// formula for that is
		//( number of vertices * (number of vertices - 1))/2

	}

	public def run(args :Array[String](1), g :Graph): Boolean {

val sw = Config.get().stopWatch();
	            // create sparse matrix
                val csr = g.createDistSparseMatrix[Double](Config.get().dist1d(), "weight", true, true);
sw.lap("Graph construction");
                // create xpregel instance
                val xpregel = XPregelGraph.make[Long, Double](csr);
val result = xpregel.stealOutput[Double]();

return true;

	}

	public static def main(args :Array[String](1)) {
		new STATS().execute(args);
	}
	
	


}
	

