package test.scalegraph.io;

import org.scalegraph.io.EdgeListReader;
import org.scalegraph.io.EdgeListWriter;
import org.scalegraph.graph.PlainGraph;

/**
 * Class TestEdgeListReader
 */
public class TestEdgeListReader {
    /**
     * Main method 
     */
    public static def main(args: Array[String]) {
    	Console.OUT.println("--------------------- Start EdgeListReader Test --------------------");
    	
        val reader:EdgeListReader = new EdgeListReader();
        Console.OUT.println("Start loading at : " + System.currentTimeMillis());
        //var testG:PlainGraph = reader.loadFromFile("/nfs/data1/miyuru/Graph Data Sets/R-MAT/scale-8.dl");
        var testG:PlainGraph = reader.loadFromFile("/nfs/data1/miyuru/Graph Data Sets/R-MAT/scale-16.dl");
        //var testG:PlainGraph = reader.loadFromFile("/data0/t2gsuzumuralab/miyuru/data/scale-16.dl");
        
        //var testG:PlainGraph = reader.loadFromFile("/nfs/data1/miyuru/twitter-kaist/newdata.dl");
        //var testG:PlainGraph = reader.loadFromFile("/data0/t2gsuzumuralab/miyuru/data/newdata.dl");
        
        Console.OUT.println("Done loading at : " + System.currentTimeMillis());
        
        testG.printCont();
        
        var vcount:Long = testG.getVertexCount();
                
        Console.OUT.println("Total vertex count : " + vcount);
        
        // val edw:EdgeListWriter = new EdgeListWriter();
        // edw.writeToFile(("8-from-plain-graph.dl"), testG as PlainGraph);
        
        Console.OUT.println("--------------------- End EdgeListreader Test ----------------------");
    }
}