import Foundation
import JavaScriptCore

let arguments = CommandLine.arguments
let code = try String(contentsOfFile: arguments[2], encoding: .utf8)
let request = try String(contentsOfFile: arguments[1], encoding: .utf8)
guard let context = JSContext() else { fatalError("no-js-context") }
context.exceptionHandler = { _, error in print("ERROR", error?.toString() ?? "unknown") }
let callback: @convention(block) (String) -> Void = { value in print(value) }
let encodeBase64: @convention(block) (String) -> String = { value in Data(value.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }).base64EncodedString() }
let decodeBase64: @convention(block) (String) -> String = { value in
    String(decoding: Data(base64Encoded: value) ?? Data(), as: UTF8.self)
}
context.setObject(callback, forKeyedSubscript: "report" as NSString)
context.setObject(encodeBase64, forKeyedSubscript: "btoa" as NSString)
context.setObject(decodeBase64, forKeyedSubscript: "atob" as NSString)
context.setObject(request, forKeyedSubscript: "input" as NSString)
context.evaluateScript("""
var self = globalThis; var window = globalThis; var location = {href:'https://runtime.eclipse.invalid/'};
var console = {log:function(){},warn:function(){},error:function(){}};
var setTimeout = function(f,t) { if(t===0) Promise.resolve().then(f); return 1; };
var clearTimeout = function(){};
var req = JSON.parse(input);
var seenHTTP = [];
function fixtureHTTP(args) {
 seenHTTP.push(args);
 var fixture=req.fixture || {};
 var body=fixture[args.url] || fixture['*'];
 if(body===undefined) throw new Error('fixture missing '+args.url);
 return {statusCode:200,headers:{'content-type':'text/html;charset=utf-8'},url:args.url,body:body};
}
var __eclipseMangayomiDartHostAsync = function(m,a){
 if(m !== 'http') return Promise.reject(new Error('host disabled '+m));
 try { return Promise.resolve(JSON.stringify(fixtureHTTP(JSON.parse(a)))); }
 catch(e) { return Promise.reject(e); }
};
var __eclipseMangayomiDartHostSync = function(m,a){throw new Error('host disabled '+m);};
var __mangayomi_native_fetch = function(url,method,headers,bodyBase64,followRedirects,timeout,resolve,reject) {
 try {
  var response=fixtureHTTP({url:url,method:method,headers:headers,bodyBase64:bodyBase64,followRedirects:followRedirects});
  resolve({status:response.statusCode,headers:response.headers,url:response.url,body:response.body});
 } catch(e) { reject(e); }
};
""")
if arguments.count > 3 {
    context.evaluateScript(try String(contentsOfFile: arguments[3], encoding: .utf8))
    context.evaluateScript("Object.assign(__eclipseMangayomiSource,req.source); Object.assign(__eclipseMangayomiPreferences,req.preferences || {});")
}
context.evaluateScript(code)
if arguments.count > 3 {
    context.evaluateScript((context.objectForKeyedSubscript("req")?.objectForKeyedSubscript("script")?.toString() ?? "") + "\nglobalThis.__eclipseMangayomiExtension=DefaultExtension;")
}
context.evaluateScript("""
(req.extractor ? __eclipseMangayomiExtract(req.extractor, JSON.stringify(req.arguments)) : req.language === 'js' ? __eclipseMangayomiJSRun(input) : __eclipseMangayomiDartRun(input))
.then(function(v){report(JSON.stringify({result:JSON.parse(v),http:seenHTTP}));},function(e){report(JSON.stringify({error:String(e)}));});
""")
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
