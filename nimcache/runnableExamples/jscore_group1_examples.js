/* Generated by the Nim Compiler v2.1.1 */
var framePtr = null;
var excHandler = 0;
var lastJSError = null;

function toJSStr(s_33556891) {
  var result_33556892 = null;

    var res_33556933 = newSeq_33556909((s_33556891).length);
    var i_33556934 = 0;
    var j_33556935 = 0;
    Label1: {
        Label2: while (true) {
        if (!(i_33556934 < (s_33556891).length)) break Label2;
          var c_33556936 = s_33556891[i_33556934];
          if ((c_33556936 < 128)) {
          res_33556933[j_33556935] = String.fromCharCode(c_33556936);
          i_33556934 += 1;
          }
          else {
            var helper_33556948 = newSeq_33556909(0);
            Label3: {
                Label4: while (true) {
                if (!true) break Label4;
                  var code_33556949 = c_33556936.toString(16);
                  if ((((code_33556949) == null ? 0 : (code_33556949).length) == 1)) {
                  helper_33556948.push("%0");;
                  }
                  else {
                  helper_33556948.push("%");;
                  }
                  
                  helper_33556948.push(code_33556949);;
                  i_33556934 += 1;
                  if ((((s_33556891).length <= i_33556934) || (s_33556891[i_33556934] < 128))) {
                  break Label3;
                  }
                  
                  c_33556936 = s_33556891[i_33556934];
                }
            };
++excHandler;
            try {
            res_33556933[j_33556935] = decodeURIComponent(helper_33556948.join(""));
--excHandler;
} catch (EXCEPTION) {
 var prevJSError = lastJSError;
 lastJSError = EXCEPTION;
 --excHandler;
            res_33556933[j_33556935] = helper_33556948.join("");
            lastJSError = prevJSError;
            } finally {
            }
          }
          
          j_33556935 += 1;
        }
    };
    if (res_33556933.length < j_33556935) { for (var i = res_33556933.length ; i < j_33556935 ; ++i) res_33556933.push(null); }
               else { res_33556933.length = j_33556935; };
    result_33556892 = res_33556933.join("");

  return result_33556892;

}

function rawEcho() {
          var buf = "";
      for (var i = 0; i < arguments.length; ++i) {
        buf += toJSStr(arguments[i]);
      }
      console.log(buf);
    

  
}
var F = {procname: "module jsbigints", prev: framePtr, filename: "/home/runner/work/nim/nim/lib/std/jsbigints.nim", line: 0};
framePtr = F;
framePtr = F.prev;
var F = {procname: "module jsbigints", prev: framePtr, filename: "/home/runner/work/nim/nim/lib/std/jsbigints.nim", line: 0};
framePtr = F;
framePtr = F.prev;
var F = {procname: "module jsutils", prev: framePtr, filename: "/home/runner/work/nim/nim/lib/std/private/jsutils.nim", line: 0};
framePtr = F;
framePtr = F.prev;
var F = {procname: "module jsutils", prev: framePtr, filename: "/home/runner/work/nim/nim/lib/std/private/jsutils.nim", line: 0};
framePtr = F;
framePtr = F.prev;
var F = {procname: "module jscore", prev: framePtr, filename: "/home/runner/work/nim/nim/lib/js/jscore.nim", line: 0};
framePtr = F;
framePtr = F.prev;
var F = {procname: "module jscore", prev: framePtr, filename: "/home/runner/work/nim/nim/lib/js/jscore.nim", line: 0};
framePtr = F;
framePtr = F.prev;

function newSeq_33556909(len_33556911) {
  var result_33556912 = [];

  var F = {procname: "newSeq.newSeq", prev: framePtr, filename: "/home/runner/work/nim/nim/lib/system.nim", line: 0};
  framePtr = F;
    F.line = 631;
    F.filename = "system.nim";
    result_33556912 = new Array(len_33556911); for (var i = 0 ; i < len_33556911 ; ++i) { result_33556912[i] = null; }  framePtr = F.prev;

  return result_33556912;

}

function HEX3Aanonymous_654311427() {
  var F = {procname: "jscore_examples_3.:anonymous", prev: framePtr, filename: "/home/runner/work/nim/nim/doc/html/nimcache/runnableExamples/jscore_examples_3.nim", line: 0};
  framePtr = F;
    F.line = 153;
    F.filename = "jscore.nim";
    rawEcho([77,105,99,114,111,116,97,115,107]);
  framePtr = F.prev;

  
}
var F = {procname: "module jscore_examples_3", prev: framePtr, filename: "/home/runner/work/nim/nim/doc/html/nimcache/runnableExamples/jscore_examples_3.nim", line: 0};
framePtr = F;
F.line = 153;
F.filename = "jscore.nim";
queueMicrotask(HEX3Aanonymous_654311427);
framePtr = F.prev;
var F = {procname: "module jscore_examples_3", prev: framePtr, filename: "/home/runner/work/nim/nim/doc/html/nimcache/runnableExamples/jscore_examples_3.nim", line: 0};
framePtr = F;
framePtr = F.prev;
var F = {procname: "module jscore_group1_examples", prev: framePtr, filename: "/home/runner/work/nim/nim/doc/html/nimcache/runnableExamples/jscore_group1_examples.nim", line: 0};
framePtr = F;
framePtr = F.prev;
var F = {procname: "module jscore_group1_examples", prev: framePtr, filename: "/home/runner/work/nim/nim/doc/html/nimcache/runnableExamples/jscore_group1_examples.nim", line: 0};
framePtr = F;
framePtr = F.prev;
