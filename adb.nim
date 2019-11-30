import net, strutils, parseutils, strformat, osproc, system, sequtils, times, math, sugar
import options except map

type FileStat = ref object of RootObj
  androidFileMode : BiggestInt
  androidFileSize : uint32
  androidFileModified : Time
  androidFileName : string

type AndroidFile = ref object of RootObj
  androidFileName : string
  androidFileStat : FileStat
  androidFile : string

proc chunkString(buf : string) : seq[string] =
  let chunkNum = (buf.len / (2^16-1)).ceil.BiggestInt
  buf.toSeq.distribute(chunkNum, false).map(chunk => chunk.map(c => $char(c)).join)

proc recvExactly(socket : Socket, length : int) : string =
  var buf = ""
  while (buf.len != length):
    buf = buf & socket.recv(length - buf.len)
  buf

proc parseAdb(resp : string) : Option[string] =
  if resp.len == 0:
    return none(string)

  var msg_len : int
  var offset : int

  var status = resp[0..3]
  var loc = parseHex(resp, msg_len, 4, 4)

  if msg_len > 0:
    offset = loc + 4 + msg_len - 1
  else:
    offset = resp.len - 1

  var msg = resp[loc+4..offset]

  if status == "FAIL":
    stderr.writeLine(msg)
    return none(string)
  return some(msg)

proc makeMsg(msg : string) : string =
  fmt"{msg.len:04x}{msg}"

proc adbConnect() : Socket =
  var socket = newSocket(buffered=false)
  socket.connect("127.0.0.1", Port(5037))
  socket

proc unrollBytes(n : uint32) : string =
  let shifts : seq[uint32] = @[0'u32, 8'u32, 16'u32, 24'u32]
  # shift each byte right by a certain amount and mask off the least-significant byte
  map(shifts, shift => $char((n shr shift) and 0x000000ff)).join

proc rollBytes(bs : string) : uint32 =
  let shifts : seq[uint32] = @[0'u32, 8'u32, 16'u32, 24'u32]
  var n : uint32
  for pair in zip(shifts, bs):
    n = n or pair.b.uint32 shl pair.a
  n

proc syncMode(): Socket =
  let socket = adbConnect()
  socket.send("host:transport-usb".makeMsg)
  discard socket.recvExactly(4)

  socket.send("sync:".makeMsg)
  discard socket.recvExactly(4).parseAdb.get

  socket

proc listDir(filename : string) : seq[FileStat] =
  let socket : Socket = syncMode()
  let filenameLen : string = filename.len.uint32.unrollBytes

  var dirents : seq[FileStat] = @[]
  var dirent : string
  var status : string

  socket.send("LIST" & filenameLen & filename)

  while(status = socket.recvExactly(4); status != "DONE"):
    dirent = socket.recvExactly(16)

    let fileMode = dirent[0..3].rollBytes.BiggestInt
    let fileSize = dirent[4..7].rollBytes
    let fileCreated = dirent[8..11].rollBytes.int64.fromUnix
    let fileNameLen = dirent[12..15].rollBytes.int
    let direntFileName = socket.recvExactly(filenameLen)

    dirents = dirents & FileStat(androidFileName: direntFileName,
                                 androidFileMode: fileMode,
                                 androidFileSize: fileSize,
                                 androidFileModified: fileCreated)
  dirents

proc recvFile(filename : string) : Option[string] =
  # Enter sync mode
  let socket : Socket = syncMode()

  let filenameLen : string = filename.len.uint32.unrollBytes

  socket.send("RECV" & filenameLen & filename)

  var recvResult : string
  var status : string = ""

  var fileBody : string
  var recvBody : string
  var fileLen : int

  var buf = ""

  while (status != "DONE"):
    recvResult = socket.recvExactly(8)

    status = recvResult[0..3]
    fileLen = recvResult[4..7].rollBytes.int

    if (fileLen == 0 or status == "DONE"):
      break

    if status == "FAIL":
      # Return early if we failed
      socket.close()
      return none(string)

    recvBody = ""

    assert(status == "DATA")
    assert(fileLen <= 0xffff and fileLen > 0, "File Length Should be <=65535 and > 0")

    recvBody = socket.recvExactly(fileLen)

    assert(recvBody.len == fileLen)

    fileBody = recvBody[0..fileLen - 1]
    buf = buf & fileBody

  assert(status == "DONE")
  assert(fileLen == 0)

  socket.close()
  return some(buf)

proc statFile(filename : string) : Option[FileStat] =
  # Enter sync mode
  let socket : Socket = syncMode()

  let filenameLen : string = filename.len.uint32.unrollBytes

  socket.send("STAT" & filenameLen & filename)

  let statResult : string = socket.recvExactly(16)

  let command = map(statResult[0..3], c => $char(c)).join
  let fileMode = statResult[4..7].rollBytes.BiggestInt
  let fileSize = statResult[8..11].rollBytes
  let fileCreated = statResult[12..15].rollBytes.int64.fromUnix

  socket.close()

  if (fileMode != 0 and fileSize != 0):
    some(FileStat(androidFileName: filename,
                  androidFileMode: fileMode,
                  androidFileSize: fileSize,
                  androidFileModified: fileCreated))
  else:
    none(FileStat)

proc sendFile(buf : string, filename : string) : bool =
  let stat = filename.statFile
  
  if stat.isSome:
    # never overwrite files
    # TODO add optional parameter to disable this
    return false

  let fileMode = fromOct[int]("0771")

  let remoteFileName = fmt"{filename},{fileMode}"

  let chunks = buf.chunkString

  echo remoteFileName

  return true
  

proc adbPull(filename : string) : Option[AndroidFile] =
  let stat = filename.statFile
  if stat.isNone:
    return none(AndroidFile)

  let fileBlob = filename.recvFile.get("")

  some(AndroidFile(androidFileName: filename,
                   androidFileStat: stat.get,
                   androidFile: fileBlob))

proc runCommand(payload : string) : string =
  var socket = adbConnect()
  socket.send("host:transport-usb".makeMsg)

  discard socket.recvExactly(4)

  socket.send(payload)

  var response = ""

  while (var chunk = socket.recv(1024); chunk != ""):
    # receive chunks until it returns nothing
    response = response & chunk

  socket.close()
  return response

proc rebootPhone() : Option[string] =
  makeMsg("reboot:").runCommand.parseAdb

proc listCerts() : string =
  makeMsg("shell:ls /etc/*").runCommand.parseAdb.get

discard execCmd("adb start-server")

#var devices = makeMsg("host:version").runCommand.parseAdb

#if devices.isNone:
  #quit(1)
#else:
  #echo devices.get()

#stdout.write adbPull("/etc/hosts").repr

#echo listDir("/etc").map(proc(f: FileStat) : string = f.androidFileName)

echo sendFile("", "/storage/7AFD-17E3/test2.opus")

#discard rebootPhone()

#echo listCerts()

#echo makeMsg("shell:uname -a").runCommand.parseAdb.get
#echo makeMsg("shell:ls /system/etc/security/cacerts/*").runCommand.parseAdb.get
