import adbtoolpkg/adb
import os, strformat

when isMainModule:
  startServer()
  let fileSource = paramStr(1)
  fileSource.androidCopyFile(fmt"/sdcard/Download/{fileSource}")
