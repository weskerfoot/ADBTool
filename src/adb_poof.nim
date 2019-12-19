import net, strutils, parseutils, strformat, osproc, sequtils
import system, times, math, sugar, os, streams
import options except map

type FileStat = ref object of RootObj
  androidFileMode : BiggestInt
  androidFileSize : uint32
  androidFileModified : Time
  androidFileName : string

type AndroidFile = ref object of RootObj
  androidFileName : string
  androidFileStat : FileStat
  androidFileContents : string

proc chunkString(buf : string) : Option[seq[string]] =
  if buf.len == 0:
    return none(seq[string])

  let chunkNum = (buf.len / (2^16-1)).ceil.BiggestInt
  some(buf.toSeq.distribute(chunkNum, false).map(chunk => chunk.map(c => $char(c)).join))

proc recvExactly(socket : Socket, length : int) : string =
  var buf = ""
  while (buf.len != length):
    buf &= socket.recv(length - buf.len)
  buf

proc parseAdb(resp : string) : Option[string] =
  if resp.len == 0:
    return none(string)

  var msg_len : int
  var offset : int

  let status = resp[0..3]
  let loc = parseHex(resp, msg_len, 4, 4)

  if msg_len > 0:
    offset = loc + 4 + msg_len - 1
  else:
    offset = resp.len - 1

  var msg = resp[loc+4..offset]

  if status == "FAIL":
    stderr.writeLine(msg)
    return none(string)
  some(msg)

proc makeMsg(msg : string) : string =
  fmt"{msg.len:04x}{msg}"

proc adbConnect() : Socket =
  let socket = newSocket(buffered=false)
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

    dirents &= FileStat(androidFileName: direntFileName,
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
    buf &= fileBody

  assert(status == "DONE")
  assert(fileLen == 0)

  socket.close()
  some(buf)

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

proc adbSend(buf : string,
             filename : string,
             permissions : string,
             overwrite = false) : bool =

  let stat = filename.statFile
  
  if stat.isSome and (not overwrite):
    # never overwrite files unless asked to
    return false

  # Enter sync mode
  let socket : Socket = syncMode()
  let fileMode = fromOct[int](fmt"0{permissions}")
  let lmtime = getTime().toUnix.uint32.unrollBytes
  let remoteFileName = fmt"{filename},{fileMode:04o}"
  let chunks = buf.chunkString

  if chunks.isNone:
    return false

  socket.send("SEND" & remoteFileName.len.uint32.unrollBytes & remoteFileName)

  for chunk in chunks.get:
    socket.send("DATA" & chunk.len.uint32.unrollBytes & chunk)

  socket.send("DONE" & lmtime)

  let serverResp = socket.recvExactly(4)

  if serverResp == "FAIL":
    let errorMsgLen = socket.recvExactly(4).rollBytes
    let errorMsg = socket.recvExactly(errorMsgLen.int)

    stderr.writeLine errorMsg
    socket.close()

    return false

  assert(serverResp == "OKAY")

  socket.close()
  true
  
proc adbPull(filename : string) : Option[AndroidFile] =
  let stat = filename.statFile
  if stat.isNone:
    return none(AndroidFile)

  let fileBlob = filename.recvFile.get("")

  some(AndroidFile(androidFileName: filename,
                   androidFileStat: stat.get,
                   androidFileContents: fileBlob))

proc runCommand(payload : string) : string =
  let socket = adbConnect()
  socket.send("host:transport-usb".makeMsg)

  discard socket.recvExactly(4)

  socket.send(payload)

  var response = ""

  while (var chunk = socket.recv(1024); chunk != ""):
    # receive chunks until it returns nothing
    response &= chunk

  socket.close()
  response

proc rebootPhone() : Option[string] =
  makeMsg("reboot:").runCommand.parseAdb

proc listCerts() : string =
  makeMsg("shell:ls -1a /etc/security/cacerts/*").runCommand.parseAdb.get

proc devices() : Option[string] =
  makeMsg("host:version").runCommand.parseAdb

discard execCmd("adb start-server")

proc parseCerts() =
  for cacert in listCerts().split("\n"):
    let certfile = adbPull(cacert)
    if certfile.isSome:
      let filename = cacert.extractFilename
      echo "Downloading " & filename
      var fileContents = certfile.get.androidFileContents
      var certFileStream = fileContents.newStringStream

proc pemRead(fp : pointer,
             x : pointer,
             pem_password_cb : pointer,
             u : pointer) : pointer {.cdecl, dynlib: "libssl.so", importc.}


parseCerts()
