"""Run source-level regression cases with an explicitly supplied Lua 5.1 library."""
import ctypes
import os
from pathlib import Path
import unittest


class Lua51:
    def __init__(self, path):
        self.library = ctypes.CDLL(str(path))
        declarations = {
            'luaL_newstate': ([], ctypes.c_void_p),
            'luaL_openlibs': ([ctypes.c_void_p], None),
            'luaL_loadbuffer': ([ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p], ctypes.c_int),
            'lua_pcall': ([ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int], ctypes.c_int),
            'lua_tolstring': ([ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)], ctypes.c_void_p),
            'lua_close': ([ctypes.c_void_p], None),
        }
        for name, (arguments, result) in declarations.items():
            function = getattr(self.library, name)
            function.argtypes = arguments
            function.restype = result

    def _run(self, source, name, execute):
        data = source.encode('utf-8') if isinstance(source, str) else source
        state = self.library.luaL_newstate()
        if not state:
            raise RuntimeError('Lua state allocation failed')
        try:
            if execute:
                self.library.luaL_openlibs(state)
            status = self.library.luaL_loadbuffer(state, data, len(data), name.encode('utf-8'))
            if status == 0 and execute:
                status = self.library.lua_pcall(state, 0, 0, 0)
            if status:
                length = ctypes.c_size_t()
                address = self.library.lua_tolstring(state, -1, ctypes.byref(length))
                message = ctypes.string_at(address, length.value).decode('utf-8', errors='replace') if address else 'Unknown Lua error'
                raise AssertionError(message)
        finally:
            self.library.lua_close(state)

    def execute(self, source, name='regression'):
        self._run(source, name, True)

    def check_syntax(self, path):
        path = Path(path)
        self._run(path.read_bytes(), '@' + path.name, False)


def load_lua51():
    configured = os.environ.get('MPVNET_TEST_LUA51')
    if not configured:
        raise unittest.SkipTest('Set MPVNET_TEST_LUA51 to an existing Lua 5.1 library to run interaction cases')
    path = Path(configured)
    if not path.is_absolute() or not path.is_file():
        raise RuntimeError('MPVNET_TEST_LUA51 must name an existing absolute library path')
    return Lua51(path)
