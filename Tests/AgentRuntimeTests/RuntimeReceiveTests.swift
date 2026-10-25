import Foundation
import CryptoKit
#if SWIFT_PACKAGE
@testable import SandboxHost
#endif

@main struct RuntimeReceiveTests {
 static func main() throws {
  var failures = 0, count = 0
  let hello = #"{"v":1,"type":"hello","id":0,"fresh":true,"interfaces":["lo"],"kernel":"test","workdir":"/work/project"}"#
  let exitFrame = #"{"v":1,"type":"exit","id":1,"code":0,"cancelled":false}"#
  let hash = SHA256.hash(data:Data("ok".utf8)).map{String(format:"%02x",$0)}.joined()
  let stream = "{\"v\":1,\"type\":\"stdout\",\"id\":1,\"data\":\"b2s=\",\"sha256\":\"\(hash)\"}"
  var bad:[(String,String,Int)] = []
  for value in ["true","1.0","1e0"] { bad.append(("v="+value,hello.replacingOccurrences(of:"\"v\":1",with:"\"v\":"+value),0)) }
  for value in ["true","1.0","1e0"] { bad.append(("id="+value,exitFrame.replacingOccurrences(of:"\"id\":1",with:"\"id\":"+value),1)) }
  for value in ["false","0.0","0e0"] { bad.append(("code="+value,exitFrame.replacingOccurrences(of:"\"code\":0",with:"\"code\":"+value),1)) }
  bad += [("duplicate conflict",hello.replacingOccurrences(of:"\"v\":1",with:"\"v\":1,\"v\":999"),0),
          ("escaped duplicate",hello.replacingOccurrences(of:"\"id\":0",with:"\"id\":0,\"\\u0069d\":0"),0),
          ("numeric fresh",hello.replacingOccurrences(of:"true",with:"1"),0),
          ("numeric cancelled",exitFrame.replacingOccurrences(of:"false",with:"0"),1),
          ("unknown field",stream.dropLast()+",\"extra\":1}",1),
          ("missing kernel",hello.replacingOccurrences(of:",\"kernel\":\"test\"",with:""),0),
          ("wrong workdir type",hello.replacingOccurrences(of:"\"/work/project\"",with:"[]"),0),
          ("bad stream hash",stream.replacingOccurrences(of:hash,with:"bad"),1),
          ("deep field",stream.dropLast()+",\"extra\":"+String(repeating:"[",count:40)+"0"+String(repeating:"]",count:40)+"}",1),
          ("oversized",hello+String(repeating:" ",count:16384),0)]
  for (label,text,command) in bad {
   count += 1; let p=AgentRuntimeProbe(); p.command=command
   var rejected=false
   do {try p.receive(Data(text.utf8))} catch {rejected=true}
   let ok=rejected && p.command==command && p.output.isEmpty && p.outputBytes==0 && !p.didCancel
   print("\(ok ? "PASS":"FAIL") reject \(label) command=\(p.command) queued=\(p.output.count) acceptedBytes=\(p.outputBytes)")
   if !ok {failures += 1}
  }
  let p=AgentRuntimeProbe();try p.receive(Data(hello.utf8));precondition(p.command==1)
  try p.receive(Data(stream.utf8));try p.receive(Data(stream.replacingOccurrences(of:"stdout",with:"stderr").utf8));precondition(p.outputBytes==4)
  try p.receive(Data(exitFrame.utf8));precondition(p.command==2);count += 1
  print("PASS valid hello/stdout/stderr/exit")
  func framed(_ text:String)->Data {let b=Data(text.utf8);var size=UInt32(b.count).bigEndian;var out=Data();withUnsafeBytes(of:&size){out.append(contentsOf:$0)};out.append(b);return out}
  let fragmented=AgentRuntimeProbe()
  for byte in framed(hello) {try fragmented.ingest(Data([byte]))}
  precondition(fragmented.command==1 && fragmented.frames==1)
  try fragmented.ingest(framed(stream)+framed(stream.replacingOccurrences(of:"stdout",with:"stderr"))+framed(exitFrame))
  precondition(fragmented.command==2 && fragmented.frames==4 && fragmented.outputBytes==4)
  count += 1; print("PASS actual ingest fragmented hello and coalesced streams/exit")
  print("RESULT cases=\(count) failures=\(failures)");Foundation.exit(failures==0 ? 0:1)
 }
}
