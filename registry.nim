## This module contains procedures that provide access to Windows Registry.
##
## .. include:: doc/modulespec.rst
include "private/winregistry"

type
  RegistryError* = object of Exception ## raised when registry-related
                                       ## error occurs.

proc splitRegPath(path: string, root: var string, other: var string): bool =
  var sliceEnd = 0
  for c in path:
    if c == '\\':
      root = substr(path, 0, sliceEnd - 1)
      other = substr(path, sliceEnd + 1, len(path) - 1)
      return true
    else:
      inc sliceEnd
  return false;

proc getPredefinedRegHandle(strkey: string): RegHandle =
  case strkey:
  of "HKEY_CLASSES_ROOT": HKEY_CLASSES_ROOT
  of "HKEY_CURRENT_USER": HKEY_CURRENT_USER
  of "HKEY_LOCAL_MACHINE": HKEY_LOCAL_MACHINE
  of "HKEY_USERS": HKEY_USERS
  of "HKEY_PERFORMANCE_DATA": HKEY_PERFORMANCE_DATA
  of "HKEY_CURRENT_CONFIG": HKEY_CURRENT_CONFIG
  of "HKEY_DYN_DATA": HKEY_DYN_DATA
  else: 0.RegHandle

proc parseRegPath(path: string, outSubkey: var string): RegHandle =
  var rootStr: string
  if not splitRegPath(path, rootStr, outSubkey):
    raise newException(RegistryError, "invalid path")
  result = getPredefinedRegHandle(rootStr)
  if result == 0.RegHandle:
    raise newException(RegistryError, "unsupported path root")

proc allocWinString(str: string): WinString {.inline.} =
  when useWinUnicode:
    if str == nil:
      return WideCString(nil)
    return newWideCString(str)
  else:
    return cstring(str)

proc regThrowOnFailInternal(hresult: LONG): void =
  when defined(debug):
    const langid = 1033 # show english error msgs
  else:
    const langid = 0
  var result: string = nil
  when useWinUnicode:
    var msgbuf: WideCString
    if formatMessageW(0x00000100 or 0x00001000 or 0x00000200 or 0x000000FF,
                      nil, hresult.int32, langid, msgbuf.addr, 0, nil) != 0'i32:
      result = $msgbuf
      if msgbuf != nil: localFree(cast[pointer](msgbuf))
  else:
    var msgbuf: cstring
    if formatMessageA(0x00000100 or 0x00001000 or 0x00000200 or 0x000000FF,
                    nil, hresult.int32, langid, msgbuf.addr, 0, nil) != 0'i32:
      result = $msgbuf
      if msgbuf != nil: localFree(msgbuf)
  if result == nil:
    raise newException(RegistryError, "unknown error")
  else:
    raise newException(RegistryError, result)

template regThrowOnFail(hresult: LONG) =
  if hresult != ERROR_SUCCESS:
    regThrowOnFailInternal(hresult)

template injectRegPathSplit(path: string) =
  var subkey {.inject.}: string
  var root {.inject.}: RegHandle = parseRegPath(path, subkey)

proc reallen(x: WinString): int {.inline.} =
  ## returns real string length in bytes, counts chars and terminating null.
  when declared(useWinUnicode):
    len(x) * 2 + 2
  else:
    len(x) + 1

proc createKeyInternal(handle: RegHandle, subkey: string,
  samDesired: RegKeyRights, outHandle: ptr RegHandle): LONG {.sideEffect.} =
  regThrowOnFail(regCreateKeyEx(handle, allocWinString(subkey), 0.DWORD, nil,
    0.DWORD, samDesired, nil, outHandle, result.addr))

proc create*(handle: RegHandle, subkey: string,
    samDesired: RegKeyRights): RegHandle {.sideEffect.} =
  ## creates new `subkey`. ``RegistryError`` is raised if key already exists.
  ##
  ## .. code-block:: nim
  ##   create(HKEY_LOCAL_MACHINE, "Software\\My Soft", samRead or samWrite)
  if createKeyInternal(handle, subkey, samDesired, result.addr) !=
      REG_CREATED_NEW_KEY:
    raise newException(RegistryError, "key already exists")

proc create*(path: string, samDesired: RegKeyRights): RegHandle {.sideEffect.} =
  ## creates new `subkey`. ``RegistryError`` is raised if key already exists.
  ##
  ## .. code-block:: nim
  ##   create("HKEY_LOCAL_MACHINE\\Software\\My Soft", samRead or samWrite)
  injectRegPathSplit(path)
  create(root, subkey, samDesired)

proc createOrOpen*(handle: RegHandle, subkey: string,
    samDesired: RegKeyRights): RegHandle {.sideEffect.} =
  ## same as `create<#create,RegHandle,string,RegKeyRights>`_ proc, but does not
  ## raise ``RegistryError`` if key already exists.
  ##
  ## .. code-block:: nim
  ##   createOrOpen(HKEY_LOCAL_MACHINE, "Software", samRead or samWrite)
  discard createKeyInternal(handle, subkey, samDesired, result.addr)

proc createOrOpen*(path: string,
    samDesired: RegKeyRights): RegHandle {.sideEffect.} =
  ## same as `create<#create,string,RegKeyRights>`_ proc, but does not
  ## raise ``RegistryError`` if key already exists.
  ##
  ## .. code-block:: nim
  ##   createOrOpen("HKEY_LOCAL_MACHINE\\Software", samRead or samWrite)
  injectRegPathSplit(path)
  result = createOrOpen(root, subkey, samDesired)

proc open*(handle: RegHandle, subkey: string,
    samDesired: RegKeyRights = samDefault): RegHandle {.sideEffect.} =
  ## opens the specified registry key. Note that key names are
  ## not case sensitive. Raises ``RegistryError`` when `handle` is invalid or
  ## `subkey` does not exist.
  ##
  ## .. code-block:: nim
  ##   open(HKEY_LOCAL_MACHINE, "Software", samRead or samWrite)
  regThrowOnFail(regOpenKeyEx(handle, allocWinString(subkey), 0.DWORD,
    samDesired, result.addr))

proc open*(path: string, samDesired: RegKeyRights = samDefault): RegHandle
    {.sideEffect.} =
  ## same as `open<#open>`_ proc, but enables specifying path without using
  ## root `RegHandle`  constants.
  ##
  ## .. code-block:: nim
  ##   open("HKEY_LOCAL_MACHINE\\Software", samRead or samWrite)
  injectRegPathSplit(path)
  result = open(root, subkey, samDesired)

proc openCurrentUser*(samDesired: RegKeyRights = samDefault): RegHandle
  {.sideEffect.} =
  ## retrieves a handle to the ``HKEY_CURRENT_USER`` key for
  ## the user the current thread is impersonating.
  regThrowOnFail(regOpenCurrentUser(samDesired, result.addr))

proc close*(handle: RegHandle) {.sideEffect.} =
  ## closes a registry `handle`. After using this proc, `handle` is no longer
  ## valid and should not be used with any registry procedures. Try to close
  ## registry handles as soon as possible.
  ##
  ## .. code-block:: nim
  ##   var h = open(HKEY_LOCAL_MACHINE, "Software", samRead)
  ##   close(h)
  discard regCloseKey(handle)

proc close*(handles: varargs[RegHandle]) {.inline, sideEffect.} =
  ## same as `close<#close>`_ proc, but allows to close several handles at once.
  ##
  ## .. code-block:: nim
  ##   var h1 = open(HKEY_LOCAL_MACHINE, "Software", samRead)
  ##   var h2 = open(HKEY_LOCAL_MACHINE, "Hardware", samRead)
  ##   close(h1, h2)
  for handle in items(handles):
    close(handle)

proc queryMaxKeyLength(handle: RegHandle): DWORD {.sideEffect.} =
  regThrowOnFail(regQueryInfoKey(handle, nullWinString, nullDwordPtr,
    nullDwordPtr, nullDwordPtr, result.addr, nullDwordPtr, nullDwordPtr,
    nullDwordPtr, nullDwordPtr, nullDwordPtr, cast[ptr FILETIME](0)))

proc countValues*(handle: RegHandle): int32 {.sideEffect.} =
  ## returns number of key-value pairs that are associated with the
  ## specified registry key. Does not count default key-value pair.
  ## The key must have been opened with the ``samQueryValue`` access right.
  regThrowOnFail(regQueryInfoKey(handle, nullWinString, nullDwordPtr,
    nullDwordPtr, nullDwordPtr, nullDwordPtr, nullDwordPtr, result.addr,
    nullDwordPtr, nullDwordPtr, nullDwordPtr, cast[ptr FILETIME](0)))

proc countSubkeys*(handle: RegHandle): int32 {.sideEffect.} =
  ## returns number of subkeys that are contained by the specified registry key.
  ## The key must have been opened with the ``samQueryValue`` access right.
  regThrowOnFail(regQueryInfoKey(handle, nullWinString, nullDwordPtr,
    nullDwordPtr, result.addr, nullDwordPtr, nullDwordPtr, nullDwordPtr,
    nullDwordPtr, nullDwordPtr, nullDwordPtr, cast[ptr FILETIME](0)))

iterator enumSubkeys*(handle: RegHandle): string {.sideEffect.} =
  ## enumerates through each subkey of the specified registry key.
  ## The key must have been opened with the ``samQueryValue`` access right.
  var
    index = 0.DWORD
    # include terminating NULL:
    sizeChars = handle.queryMaxKeyLength + 1
    buff = alloc(sizeChars * sizeof(WinChar))

  while true:
    var numCharsReaded = sizeChars
    var returnValue = regEnumKeyEx(handle, index, cast[WinString](buff),
      numCharsReaded.addr, cast[ptr DWORD](0.DWORD), cast[WinString](0),
      cast[ptr DWORD](0.DWORD), cast[ptr FILETIME](0.DWORD))

    case returnValue
    # of ERROR_MORE_DATA:
    #   sizeChars += 10
    #   buff = realloc(buff, sizeChars * sizeof(WinChar))
    #   continue
    of ERROR_NO_MORE_ITEMS:
      dealloc(buff)
      break;
    of ERROR_SUCCESS:
      yield $(cast[WinString](buff))
      inc index
    else:
      dealloc(buff)
      regThrowOnFailInternal(returnValue)
      break

proc writeString*(handle: RegHandle, key, value: string) {.sideEffect.} =
  ## writes value of type ``REG_SZ`` to specified key.
  ##
  ## .. code-block:: nim
  ##   writeString(handle, "hello", "world")
  var valueWS = allocWinString(value)
  regThrowOnFail(regSetValueEx(handle, allocWinString(key), 0.DWORD, regSZ,
    cast[pointer](valueWS), (reallen(valueWS)).DWORD))

proc writeExpandString*(handle: RegHandle, key, value: string) {.sideEffect.} =
  ## writes value of type ``REG_EXPAND_SZ`` to specified key.
  var valueWS = allocWinString(value)
  regThrowOnFail(regSetValueEx(handle, allocWinString(key), 0.DWORD,
    regExpandSZ, cast[pointer](valueWS), (reallen(valueWS)).DWORD))

proc writeMultiString*(handle: RegHandle, key: string, value: openArray[string])
    {.sideEffect.} =
  ## writes value of type ``REG_MULTI_SZ`` to specified key. Empty strings are
  ## not allowed and being skipped.
  # each ansi string separated by \0, unicode string by \0\0
  # last string has additional \0 or \0\0
  var data: seq[WinChar] = @[]
  for str in items(value):
    if str == nil or len(str) == 0: continue
    var strWS = allocWinString(str)
    # not 0..strLen-1 because we need '\0' or '\0\0' too
    for i in 0..len(strWS):
      data.add(strWS[i])
  data.add(0.WinChar) # same as '\0'
  regThrowOnFail(regSetValueEx(handle, allocWinString(key), 0.DWORD, regMultiSZ,
    data[0].addr, data.len().DWORD * sizeof(WinChar).DWORD))

proc writeInt32*(handle: RegHandle, key: string, value: int32) {.sideEffect.} =
  ## writes value of type ``REG_DWORD`` to specified key.
  regThrowOnFail(regSetValueEx(handle, allocWinString(key), 0.DWORD, regDword,
    value.unsafeAddr, sizeof(int32).DWORD))

proc writeInt64*(handle: RegHandle, key: string, value: int64) {.sideEffect.} =
  ## writes value of type ``REG_QWORD`` to specified key.
  regThrowOnFail(regSetValueEx(handle, allocWinString(key), 0.DWORD, regQword,
    value.unsafeAddr, sizeof(int64).DWORD))

proc writeBinary*(handle: RegHandle, key: string, value: openArray[byte])
    {.sideEffect.} =
  ## writes value of type ``REG_BINARY`` to specified key.
  regThrowOnFail(regSetValueEx(handle, allocWinString(key), 0.DWORD, regBinary,
    value[0].unsafeAddr, value.len().DWORD))

template injectRegKeyReader(handle: RegHandle, key: string,
  allowedDataTypes: DWORD) {.immediate.} =
  ## dont forget to dealloc buffer
  var
    size {.inject.}: DWORD = 32
    buff {.inject.}: pointer = alloc(size)
    kind: RegValueKind
    keyWS = allocWinString(key)
    status = regGetValue(handle, nil, keyWS, allowedDataTypes, kind.addr,
      buff, size.addr)
  if status == ERROR_MORE_DATA:
    # size now stores amount of bytes, required to store value in array
    buff = realloc(buff, size)
    status = regGetValue(handle, nil, keyWS, allowedDataTypes, kind.addr,
      buff, size.addr)
  if status != ERROR_SUCCESS:
    dealloc(buff)
    regThrowOnFailInternal(status)

proc readString*(handle: RegHandle, key: string): TaintedString {.sideEffect.} =
  ## reads value of type ``REG_SZ`` from registry key.
  injectRegKeyReader(handle, key, RRF_RT_REG_SZ)
  result = TaintedString($(cast[WinString](buff)))
  dealloc(buff)

proc readExpandString*(handle: RegHandle, key: string): TaintedString
    {.sideEffect.} =
  ## reads value of type ``REG_EXPAND_SZ`` from registry key. The key must have
  ## been opened with the ``samQueryValue`` access right.
  ## Use `expandEnvString<#expandEnvString>`_ proc to expand environment
  ## variables.
  # data not supported error thrown without RRF_NOEXPAND
  injectRegKeyReader(handle, key, RRF_RT_REG_EXPAND_SZ or RRF_NOEXPAND)
  result = TaintedString($(cast[WinString](buff)))
  dealloc(buff)

proc readMultiString*(handle: RegHandle, key: string): seq[string]
    {.sideEffect.} =
  ## reads value of type ``REG_MULTI_SZ`` from registry key.
  injectRegKeyReader(handle, key, RRF_RT_REG_MULTI_SZ)
  result = @[]
  var strbuff = cast[cstring](buff)
  var
    i = 0
    strBegin = 0
    running = true
    nullchars = 0
  # each string separated by '\0', last string is `\0\0`
  # unicode string separated by '\0\0', last str is '\0\0\0\0'
  when useWinUnicode:
    while running:
      #echo "iter", i, ", c: ", strbuff[i].byte, ", addr: ", cast[int](buff) + i
      if strbuff[i] == '\0' and strbuff[i+1] == '\0':
        inc nullchars
        if nullchars == 2:
          running = false
        else:
          #echo "str at ", cast[int](buff) + strBegin
          result.add $cast[WinString](cast[int](buff) + strBegin)
          strBegin = i + 2
      else:
        nullchars = 0
      inc(i, 2)
  else:
    while running:
      #echo "iter", i, ", c: ", strbuff[i].byte, ", addr: ", cast[int](buff) + i
      if strbuff[i] == '\0':
        inc nullchars
        if nullchars == 2:
          running = false
        else:
          #echo "str at ", cast[int](buff) + strBegin
          result.add $cast[WinString](cast[int](buff) + strBegin)
          strBegin = i + 1
      else:
        nullchars = 0
      inc(i)

proc readInt32*(handle: RegHandle, key: string): int32 {.sideEffect.} =
  ## reads value of type ``REG_DWORD`` from registry key. The key must have
  ## been opened with the ``samQueryValue`` access right.
  var
    size: DWORD = sizeof(result).DWORD
    keyWS = allocWinString(key)
    status = regGetValue(handle, nil, keyWS, RRF_RT_REG_DWORD, nil,
      result.addr, size.addr)
  regThrowOnFail(status)

proc readInt64*(handle: RegHandle, key: string): int64 {.sideEffect.} =
  ## reads value of type ``REG_QWORD`` from registry entry. The key must have
  ## been opened with the ``samQueryValue`` access right.
  var
    size: DWORD = sizeof(result).DWORD
    keyWS = allocWinString(key)
    status = regGetValue(handle, nil, keyWS, RRF_RT_REG_QWORD, nil,
      result.addr, size.addr)
  regThrowOnFail(status)

proc readBinary*(handle: RegHandle, key: string): seq[byte] {.sideEffect.} =
  ## reads value of type ``REG_BINARY`` from registry entry. The key must have
  ## been opened with the ``samQueryValue`` access right.
  injectRegKeyReader(handle, key, RRF_RT_REG_BINARY)
  result = newSeq[byte](size)
  copyMem(result[0].addr, buff, size)
  dealloc(buff)

proc delSubkey*(handle: RegHandle, subkey: string,
  samDesired: RegKeyRights = samDefault) {.sideEffect.} =
  ## deletes a subkey and its values from the specified platform-specific
  ## view of the registry. Note that key names are not case sensitive.
  ## The subkey to be deleted must not have subkeys. To delete a key and all it
  ## subkeys, you need to enumerate the subkeys and delete them individually.
  ## To delete keys recursively, use the `delTree<#delTree>`_.
  ##
  ## `samDesired` should be ``samWow32`` or ``samWow64``.
  regThrowOnFail(regDeleteKeyEx(handle, allocWinString(subkey), samDesired,
    0.DWORD))

proc delTree*(handle: RegHandle, subkey: string) {.sideEffect.} =
  ## deletes the subkeys and values of the specified key recursively. `subkey`
  ## can be ``nil``, in that case, all subkeys of `handle` is deleted.
  ##
  ## The key must have been opened with ``samDelete``, ``samEnumSubkeys``
  ## and ``samQueryValue`` access rights.
  regThrowOnFail(regDeleteTree(handle, allocWinString(subkey)))

proc expandEnvString*(str: string): string =
  ## helper proc to expand strings returned by
  ## `readExpandString<#readExpandString>`_ proc. If string cannot be expanded,
  ## ``nil`` returned.
  ##
  ## .. code-block:: nim
  ##  echo expandEnvString("%PATH%") # => C:\Windows;C:\Windows\system32...
  var
    size: DWORD = 32 * sizeof(WinChar)
    buff: pointer = alloc(size)
    valueWS = allocWinString(str)
  var returnValue = expandEnvironmentStrings(valueWS, buff, size)
  if returnValue == 0:
    dealloc(buff)
    return nil
  # return value is in TCHARs, aka number of chars returned, not number of
  # bytes required to store string
  # WinChar is `char` or `Utf16Char` depending on useWinUnicode const in winlean
  # actually needs to be checked because without this line everything works okay
  returnValue = returnValue * sizeof(WinChar).DWORD
  if returnValue > size:
    # buffer size was not enough to expand string
    size = returnValue
    buff = realloc(buff, size)
    returnValue = expandEnvironmentStrings(valueWS, buff, size)
  if returnValue == 0:
    dealloc(buff)
    return nil
  result = $(cast[WinString](buff))
  dealloc(buff)

when compileOption("taintmode"):
  proc expandEnvString*(str: TaintedString): string =
    ## expandEnvString for TaintedString.
    expandEnvString(str.string)

when isMainModule:
  var pass: bool = true
  var msg, stacktrace: string
  var h: RegHandle
  try:
    h = createOrOpen("HKEY_LOCAL_MACHINE\\Software\\AAAnim_reg_test",
      samRead or samWrite or samWow32)
    h.writeString("strkey", "strval")
    assert(string(h.readString("strkey")) == "strval")
    h.writeString("path", "C:\\dir\\myfile")
    assert h.readString("path").string == "C:\\dir\\myfile"
    h.writeBinary("hello", [0xff.byte, 0x00])
    var dat = h.readBinary("hello")
    assert(dat[0] == 0xff)
    assert(dat[1] == 0x00)
    h.writeInt32("123x86", 12341234)
    assert(h.readInt32("123x86") == 12341234)
    h.writeInt64("123x64", 1234123412341234)
    assert(h.readInt64("123x64") == 1234123412341234)
    h.writeExpandString("helloexpand", "%PATH%")
    assert(h.readExpandString("helloexpand").expandEnvString() != "%PATH%")
    h.writeMultiString("hellomult", ["sup!", "\u03AB世界", "世ϵ界", "", nil])
    var datmult = h.readMultiString("hellomult")
    assert(datmult.len == 3)
    assert(datmult[0] == "sup!")
    assert(datmult[1] == "\u03AB世界")
    assert(datmult[2] == "世ϵ界")
    var x = create(h, "test_sk", samAll)
    assert(countSubkeys(x) == 0)
    assert(countValues(x) == 0)
    close(x)
    h.delSubkey("test_sk")
    close(h)
    HKEY_LOCAL_MACHINE.delSubkey("Software\\AAAnim_reg_test", samWow32)
    #for sk in enumSubkeys(h):
    #  echo sk
  except RegistryError, AssertionError:
    pass = false
    msg = getCurrentExceptionMsg()
    stacktrace = getStackTrace(getCurrentException())
  finally:
    close(h)
    if pass:
      echo "tests passed"
      quit(QuitSuccess)
    else:
      echo "tests failed: ", msg
      echo stacktrace
      quit(QuitFailure)
