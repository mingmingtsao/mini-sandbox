import Foundation
import CryptoKit
import Darwin

func regular(_ path: URL,_ maximum:Int) throws -> Data {
    let fd=open(path.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);guard fd>=0 else{throw AgentRuntimeProbe.Failure.io};defer{close(fd)}
    var info=stat();guard fstat(fd,&info)==0,(info.st_mode & S_IFMT)==S_IFREG,info.st_nlink==1,info.st_uid==getuid(),info.st_mode & 0o022 == 0,info.st_size>0,info.st_size<=maximum else{throw AgentRuntimeProbe.Failure.io}
    var result=Data();var b=[UInt8](repeating:0,count:65536)
    while true{let n=read(fd,&b,b.count);if n==0{break};guard n>0,result.count+n<=maximum else{throw AgentRuntimeProbe.Failure.io};result.append(contentsOf:b.prefix(n))}
    return result
}
func safeDirectory(_ url:URL) throws {
    var current=url.standardizedFileURL
    var leaf=true
    while true {
        var s=stat()
        guard lstat(current.path,&s)==0,(s.st_mode&S_IFMT)==S_IFDIR,
              (s.st_uid==getuid() || s.st_uid==0),s.st_mode & 0o022 == 0 else{throw AgentRuntimeProbe.Failure.io}
        if leaf {guard s.st_uid==getuid(),s.st_mode & 0o077 == 0 else{throw AgentRuntimeProbe.Failure.io};leaf=false}
        if current.path=="/" {break}
        current=current.deletingLastPathComponent()
    }
}
func digest(_ d:Data)->String{SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined()}

do {
    guard CommandLine.arguments.count==3 else{throw AgentRuntimeProbe.Failure.frame}
    for path in CommandLine.arguments.dropFirst() {
        guard path.hasPrefix("/"), !path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0=="." || $0==".."}) else{throw AgentRuntimeProbe.Failure.io}
    }
    let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true),session=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
    try safeDirectory(root);try safeDirectory(session)
    guard let manifest=try JSONSerialization.jsonObject(with:regular(root.appendingPathComponent("runtime.json"),4*1024*1024)) as? [String:Any] else{throw AgentRuntimeProbe.Failure.frame}
    let kernel=root.appendingPathComponent("Image"),ramdisk=root.appendingPathComponent("runtime.cpio.gz")
    guard try digest(regular(kernel,64*1024*1024))=="256d5fff4bb892edcb9218c1e6353e388bc3646e65f76c2bc9d958b635d1b00e",try digest(regular(ramdisk,128*1024*1024))==manifest["initramfsSHA256"] as? String else{throw AgentRuntimeProbe.Failure.digest}
    let disk=session.appendingPathComponent("private.raw")
    let fd=open(disk.path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);guard fd>=0 else{throw AgentRuntimeProbe.Failure.io}
    guard ftruncate(fd,67108864)==0 else{close(fd);throw AgentRuntimeProbe.Failure.io};close(fd)
    let probe=AgentRuntimeProbe();exit(probe.run(kernel:kernel,ramdisk:ramdisk,disk:disk))
}catch{print("runtime preparation rejected: \(error)");exit(1)}
