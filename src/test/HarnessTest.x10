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
package test;

import org.scalegraph.test.STest;

final class HarnessTest extends STest {
	public static def main(args: Rail[String]) {
		new HarnessTest().execute(args);
	}

	public def run(args:Rail[String]) :boolean {
		finish for(p in Place.places()) at(p) async {
			throw new NullPointerException("Exception for test");
		}
		return true;
	}
}
