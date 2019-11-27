import net, strutils, parseutils, strformat, osproc, system, sequtils, times
import options except map

type FileStat = ref object of RootObj
  androidFileMode : BiggestInt
  androidFileSize : uint32
  androidFileModified : Time

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
  map(shifts, proc (shift : uint32) : string = $char((n shr shift) and 0x000000ff)).join

proc rollBytes(bs : string) : uint32 =
  let shifts : seq[uint32] = @[0'u32, 8'u32, 16'u32, 24'u32]
  var n : uint32
  for pair in zip(shifts, bs):
    n = n or pair.b.uint32 shl pair.a
  n

proc syncMode(): Socket =
  let socket = adbConnect()
  socket.send("host:transport-usb".makeMsg)
  discard socket.recv(1024)

  echo "Trying to set sync mode"
  socket.send("sync:".makeMsg)
  discard socket.recv(1024).parseAdb.get

  socket

proc recvFile(filename : string) : Option[string] =
  # TODO handle more than one chunk :)
  let socket : Socket = syncMode()

  echo fmt"Trying to receive the file {filename}"

  let filenameLen : string = filename.len.uint32.unrollBytes

  socket.send("RECV" & filenameLen & filename)

  let recvResult = socket.recv(8) # 64 kb + 8 bytes

  echo "received the chunk"

  let status = recvResult[0..3]

  if status == "FAIL":
    # Return early if we failed
    socket.close()
    return none(string)

  echo "Getting the file length"
  let fileLen = recvResult[4..7].rollBytes.int

  assert(fileLen <= 0xffff, "File Length Should be <=65535!")

  let recvBody = socket.recv(fileLen) # max 64kb length

  echo "Getting the file body"
  let fileBody = recvBody[0..fileLen-1]

  socket.close()
  return some(fileBody)

proc statFile(filename : string) : FileStat =
  let socket : Socket = syncMode()

  echo fmt"Trying to stat the file {filename}"

  let filenameLen : string = filename.len.uint32.unrollBytes

  socket.send("STAT" & filenameLen & filename)

  let statResult : string = socket.recv(1024)

  let command = map(statResult[0..3], proc (c : char) : string = $char(c)).join
  let fileMode = statResult[4..7].rollBytes.BiggestInt
  let fileSize = statResult[8..11].rollBytes
  let fileCreated = statResult[12..15].rollBytes.int64.fromUnix

  socket.close()

  FileStat(androidFileMode: fileMode,
           androidFileSize: fileSize,
           androidFileModified: fileCreated)

proc adbPull(filename : string) : string =
  echo filename.len
  echo filename.statFile.repr

  echo filename.recvFile

  return ""

proc sendAdb(payload : string) : string =
  var socket = adbConnect()
  socket.send("host:transport-usb".makeMsg)

  discard socket.recv(1024)

  socket.send(payload)

  var response = ""

  while (var chunk = socket.recv(1024); chunk != ""):
    response = response & chunk

  socket.close()
  return response

proc rebootPhone() : Option[string] =
  makeMsg("reboot:").sendAdb.parseAdb

proc listCerts() : string =
  makeMsg("shell:ls /etc/*").sendAdb.parseAdb.get

discard execCmd("adb start-server")

#var devices = makeMsg("host:version").sendAdb.parseAdb

#if devices.isNone:
  #quit(1)
#else:
  #echo devices.get()

echo adbPull("/etc/whitelistedapps.xml")

#discard rebootPhone()

#echo listCerts()

#echo makeMsg("shell:uname -a").sendAdb.parseAdb.get
#echo makeMsg("shell:ls /system/etc/security/cacerts/*").sendAdb.parseAdb.get
