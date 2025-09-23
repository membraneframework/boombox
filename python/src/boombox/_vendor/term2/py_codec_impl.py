# Copyright 2018, Erlang Solutions Ltd, and S2HC Sweden AB
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

""" Module implements encoder and decoder from ETF (Erlang External Term Format)
    used by the network distribution layer.
"""
import math
import struct
from typing import Callable, Union, Optional, Any, Type, Dict, Tuple, Set

from zlib import decompressobj

from term import util
from term.atom import Atom, StrictAtom
from term.basetypes import Term
from term.fun import Fun
from term.list import NIL, ImproperList
from term.pid import Pid
from term.bitstring import BitString
from term.reference import Reference

ETF_VERSION_TAG = 131

TAG_ATOM_EXT = 100
TAG_ATOM_UTF8_EXT = 118

TAG_BINARY_EXT = 109
TAG_BIT_BINARY_EXT = 77

TAG_COMPRESSED = 80

TAG_FLOAT_EXT = 99

TAG_INT = 98

TAG_LARGE_BIG_EXT = 111
TAG_LARGE_TUPLE_EXT = 105
TAG_LIST_EXT = 108

TAG_MAP_EXT = 116

TAG_NEW_FLOAT_EXT = 70
TAG_NEW_FUN_EXT = 112
TAG_NEW_REF_EXT = 114
TAG_NIL_EXT = 106

TAG_PID_EXT = 103

TAG_SMALL_ATOM_EXT = 115
TAG_SMALL_ATOM_UTF8_EXT = 119
TAG_SMALL_BIG_EXT = 110
TAG_SMALL_INT = 97
TAG_SMALL_TUPLE_EXT = 104
TAG_STRING_EXT = 107

TAG_NEW_PID_EXT = 88
TAG_NEWER_REF_EXT = 90

EncodeHookType = Optional[Dict[str, Callable[[Any], Any]]]


# This is Python variant of codec exception when Python impl is used.
# Otherwise native lib defines its own exception with same name.
# To use this, import via codec.py
class PyCodecError(Exception):
    pass


def incomplete_data(where=""):
    """ This is called from many places to report incomplete data while
        decoding.
    """
    if where:
        raise PyCodecError("Incomplete data at " + where)
    else:
        raise PyCodecError("Incomplete data")


def binary_to_term(data: bytes, options: Optional[dict] = None) -> Tuple[Term, bytes]:
    """ Strip 131 header and unpack if the data was compressed.

        :param data: The incoming encoded data with the 131 byte
        :param options:
               * "atom": "str" | "bytes" | "Atom" | "StrictAtom" (default "Atom").
                 Returns atoms as strings, as bytes or as atom.Atom objects.
               * "byte_string": "str" | "bytes" | "int_list" (default "str").
                 Returns 8-bit strings as Python str or bytes or list of integers.
               * "decode_hook" : callable. Python function called for each
                 decoded term.
        :raises PyCodecError: when the tag is not 131, when compressed
            data is incomplete or corrupted
        :returns: Remaining unconsumed bytes
    """
    if options is None:
        options = {}

    if data[0] != ETF_VERSION_TAG:
        raise PyCodecError("Unsupported external term version")

    if data[1] == TAG_COMPRESSED:
        do = decompressobj()
        decomp_size = util.u32(data, 2)
        decode_data = do.decompress(data[6:]) + do.flush()
        if len(decode_data) != decomp_size:
            # Data corruption?
            raise PyCodecError("Compressed size mismatch with actual")
    else:
        decode_data = data[1:]

    decode_hook = options.get('decode_hook', {})
    val, rem = binary_to_term_2(decode_data, options)
    type_name_ref = type(val).__name__
    if type_name_ref in decode_hook:
        return decode_hook.get(type_name_ref)(val), rem
    else:
        return val, rem


def _bytes_to_atom(name: bytes, encoding: str, create_atom_fn: Callable) \
        -> Optional[Union[Atom, bool]]:
    """ Recognize familiar atom values. """
    if name == b'true':
        return True
    elif name == b'false':
        return False
    elif name == b'undefined':
        return None
    else:
        return create_atom_fn(name, encoding)


def _get_create_atom_fn(opt: str, create_fn: Callable[[str], Atom]) -> Callable:
    def _create_atom_bytes(name: bytes, _encoding: str) -> bytes:
        return name

    def _create_atom_str(name: bytes, encoding: str) -> str:
        return name.decode(encoding)

    def _create_atom_atom(name: bytes, encoding: str) -> Atom:
        return Atom(name.decode(encoding))

    def _create_atom_strict_atom(name: bytes, encoding: str) -> Atom:
        return StrictAtom(name.decode(encoding))

    def _create_atom_custom(name: bytes, encoding: str) -> object:
        return create_fn(name.decode(encoding))

    if create_fn is not None:
        return _create_atom_custom
    if opt == "Atom":
        return _create_atom_atom
    elif opt == "StrictAtom":
        return _create_atom_strict_atom
    elif opt == "str":
        return _create_atom_str
    elif opt == "bytes":
        return _create_atom_bytes

    raise PyCodecError("Option 'atom' is '%s'; expected 'str', 'bytes', "
                       "'Atom', StrictAtom")


def _get_create_str_fn(opt: str) -> Callable:
    """ A tool function to create either a str or bytes from a 8-bit string. """

    def _create_int_list(name: bytes) -> list:
        return list(name)

    def _create_str_bytes(name: bytes) -> bytes:
        return name

    def _create_str_str(name: bytes) -> str:
        return name.decode("latin-1")

    if opt == "str":
        return _create_str_str
    elif opt == "bytes":
        return _create_str_bytes
    elif opt == "int_list":
        return _create_int_list

    raise PyCodecError("Option 'byte_string' is '%s'; expected 'str', 'bytes'")


def binary_to_term_2(data: bytes, options: Optional[dict] = None) -> Tuple[Term, bytes]:
    """ Proceed decoding after leading tag has been checked and removed.

        Erlang lists are decoded into ``term.List`` object, whose ``elements_``
        field contains the data, ``tail_`` field has the optional tail and a
        helper function exists to assist with extracting an unicode string.

        Atoms are decoded to :py:class:`~Term.atom.Atom` or optionally to bytes
        or to strings. If `atom_call` is provided that will be called and the
        returned value will be used as representation if atoms
        Pids are decoded into :py:class:`~Term.pid.Pid`.
        Refs decoded to and :py:class:`~Term.reference.Reference`.
        Maps are decoded into Python ``dict``.
        Binaries are decoded into ``bytes``
        object and bitstrings into a pair of ``(bytes, last_byte_bits:int)``.

        :param options: dict(str, _);
                * "atom": "str" | "bytes" | "Atom" | "StrictAtom"; default "Atom".
                  Returns atoms as strings, as bytes or as atom.Atom class objects
                * "atom_call": callable object that will get str as input the
                  returned value will be used as atom representation
                * "byte_string": "str" | "bytes" | "int_list" (default "str").
                  Returns 8-bit strings as Python str or bytes or int list.
        :param data: Bytes containing encoded term without 131 header
        :rtype: Tuple[Value, Tail: bytes]
        :return: The function consumes as much data as
            possible and returns the tail. Tail can be used again to parse
            another term if there was any.
        :raises PyCodecError(str): on various errors
    """
    if options is None:
        options = {}

    atom_call_opt = options.get("atom_call")
    create_atom_fn = _get_create_atom_fn(
        options.get("atom", "Atom"),
        atom_call_opt if callable(atom_call_opt) else None)
    create_str_fn = _get_create_str_fn(options.get("byte_string", "str"))

    tag = data[0]

    if tag in [TAG_ATOM_EXT, TAG_ATOM_UTF8_EXT]:
        len_data = len(data)
        if len_data < 3:
            return incomplete_data("decoding length for an atom name")

        len_expected = util.u16(data, 1) + 3
        if len_expected > len_data:
            return incomplete_data("decoding text for an atom")

        name = data[3:len_expected]
        enc = 'latin-1' if tag == TAG_ATOM_EXT else 'utf8'
        return _bytes_to_atom(name, enc, create_atom_fn), data[len_expected:]

    if tag in [TAG_SMALL_ATOM_EXT, TAG_SMALL_ATOM_UTF8_EXT]:
        len_data = len(data)
        if len_data < 2:
            return incomplete_data("decoding length for a small-atom name")

        len_expected = data[1] + 2
        name = data[2:len_expected]

        enc = 'latin-1' if tag == TAG_SMALL_ATOM_EXT else 'utf8'
        return _bytes_to_atom(name, enc, create_atom_fn), data[len_expected:]

    if tag == TAG_NIL_EXT:
        return [], data[1:]

    if tag == TAG_STRING_EXT:
        len_data = len(data)
        if len_data < 3:
            return incomplete_data("decoding length for a string")

        len_expected = util.u16(data, 1) + 3

        if len_expected > len_data:
            return incomplete_data()

        return create_str_fn(data[3:len_expected]), data[len_expected:]

    if tag == TAG_LIST_EXT:
        if len(data) < 5:
            return incomplete_data("decoding length for a list")
        len_expected = util.u32(data, 1)
        result_l = []
        tail = data[5:]
        while len_expected > 0:
            term1, tail = binary_to_term_2(tail)
            result_l.append(term1)
            len_expected -= 1

        # Read list tail and set it
        list_tail, tail = binary_to_term_2(tail)
        if list_tail == NIL:
            return result_l, tail
        return ImproperList(result_l, list_tail), tail

    if tag == TAG_SMALL_TUPLE_EXT:
        if len(data) < 2:
            return incomplete_data("decoding length for a small tuple")
        len_expected = data[1]
        result_t = []
        tail = data[2:]
        while len_expected > 0:
            term1, tail = binary_to_term_2(tail)
            result_t.append(term1)
            len_expected -= 1

        return tuple(result_t), tail

    if tag == TAG_LARGE_TUPLE_EXT:
        if len(data) < 5:
            return incomplete_data("decoding length for a large tuple")
        len_expected = util.u32(data, 1)
        result_lt = []
        tail = data[5:]
        while len_expected > 0:
            term1, tail = binary_to_term_2(tail)
            result_lt.append(term1)
            len_expected -= 1

        return tuple(result_lt), tail

    if tag == TAG_SMALL_INT:
        if len(data) < 2:
            return incomplete_data("decoding a 8-bit small uint")
        return data[1], data[2:]

    if tag == TAG_INT:
        if len(data) < 5:
            return incomplete_data("decoding a 32-bit int")
        return util.i32(data, 1), data[5:]

    if tag == TAG_PID_EXT:
        node, tail = binary_to_term_2(data[1:])
        id1 = util.u32(tail, 0)
        serial = util.u32(tail, 4)
        creation = tail[8]

        assert isinstance(node, Atom)
        pid1 = Pid(node_name=node,
                   id=id1,
                   serial=serial,
                   creation=creation)
        return pid1, tail[9:]

    if tag == TAG_NEW_PID_EXT:
        node, tail = binary_to_term_2(data[1:])
        id1 = util.u32(tail, 0)
        serial = util.u32(tail, 4)
        creation = util.u32(tail, 8)

        assert isinstance(node, Atom)
        pid2 = Pid(node_name=node,
                   id=id1,
                   serial=serial,
                   creation=creation)
        return pid2, tail[12:]

    if tag == TAG_NEW_REF_EXT:
        if len(data) < 2:
            return incomplete_data("decoding length for a new-ref")
        term_len = util.u16(data, 1)
        node, tail = binary_to_term_2(data[3:])
        creation = tail[0]
        id_len = 4 * term_len
        id1 = tail[1:id_len + 1]

        ref = Reference(node_name=node,
                        creation=creation,
                        refid=id1)
        return ref, tail[id_len + 1:]

    if tag == TAG_NEWER_REF_EXT:
        if len(data) < 2:
            return incomplete_data("decoding length for a newer-ref")
        term_len = util.u16(data, 1)
        node, tail = binary_to_term_2(data[3:])
        creation = util.u32(tail, 0)
        id_len = 4 * term_len
        id1 = tail[4:id_len + 4]

        ref = Reference(node_name=node,
                        creation=creation,
                        refid=id1)
        return ref, tail[id_len + 4:]

    if tag == TAG_MAP_EXT:
        if len(data) < 5:
            return incomplete_data("decoding length for a map")
        len_expected = util.u32(data, 1)
        result_m = {}
        tail = data[5:]
        while len_expected > 0:
            term1, tail = binary_to_term_2(tail)
            term2, tail = binary_to_term_2(tail)
            result_m[term1] = term2
            len_expected -= 1

        return result_m, tail

    if tag == TAG_BINARY_EXT:
        len_data = len(data)
        if len_data < 5:
            return incomplete_data("decoding length for a binary")
        len_expected = util.u32(data, 1) + 5
        if len_expected > len_data:
            return incomplete_data("decoding data for a binary")

        # Returned as Python `bytes`
        return data[5:len_expected], data[len_expected:]

    if tag == TAG_BIT_BINARY_EXT:
        len_data = len(data)
        if len_data < 6:
            return incomplete_data("decoding length for a bit-binary")
        len_expected = util.u32(data, 1) + 6
        lbb = data[5]
        if len_expected > len_data:
            return incomplete_data("decoding data for a bit-binary")

        # Returned as tuple `(bytes, last_byte_bits:int)`
        return (data[6:len_expected], lbb), data[len_expected:]

    if tag == TAG_NEW_FLOAT_EXT:
        (result_f,) = struct.unpack(">d", data[1:9])
        return result_f, data[9:]

    if tag == TAG_SMALL_BIG_EXT:
        nbytes = data[1]
        # Data is encoded little-endian as bytes (least significant first)
        in_bytes = data[3:(3 + nbytes)]
        # NOTE: int.from_bytes is Python 3.2+
        result_bi = int.from_bytes(in_bytes, byteorder='little')
        if data[2] != 0:
            result_bi = -result_bi
        return result_bi, data[3 + nbytes:]

    if tag == TAG_LARGE_BIG_EXT:
        nbytes = util.u32(data, 1)
        # Data is encoded little-endian as bytes (least significant first)
        in_bytes = data[6:(6 + nbytes)]
        # NOTE: int.from_bytes is Python 3.2+
        result_lbi = int.from_bytes(in_bytes, byteorder='little')
        if data[5] != 0:
            result_lbi = -result_lbi
        return result_lbi, data[6 + nbytes:]

    if tag == TAG_NEW_FUN_EXT:
        # size = util.u32(data, 1)
        arity = data[5]
        uniq = data[6:22]
        index = util.u32(data, 22)
        num_free = util.u32(data, 26)
        (mod, tail) = binary_to_term_2(data[30:])
        (old_index, tail) = binary_to_term_2(tail)
        (old_uniq, tail) = binary_to_term_2(tail)
        (pid3, tail) = binary_to_term_2(tail)

        free_vars = []
        while num_free > 0:
            (v, tail) = binary_to_term_2(tail)
            free_vars.append(v)
            num_free -= 1

        return Fun(mod=mod,
                   arity=arity,
                   pid=pid3,
                   index=index,
                   uniq=uniq,
                   old_index=old_index,
                   old_uniq=old_uniq,
                   free=free_vars), tail

    raise PyCodecError("Unknown tag %d" % data[0])


def _pack_list(lst, tail, encode_hook: EncodeHookType):
    if len(lst) == 0:
        return bytes([TAG_NIL_EXT])

    data = b''
    for item in lst:
        data += term_to_binary_2(item, encode_hook)

    tail = term_to_binary_2(tail, encode_hook)
    return bytes([TAG_LIST_EXT]) + util.to_u32(len(lst)) + data + tail


def _pack_string(val):
    if len(val) == 0:
        return _pack_list([], [], encode_hook=None)

    # Save time here and don't check list elements to fit into a byte
    # Otherwise TODO: if all elements were bytes - we could use TAG_STRING_EXT

    return _pack_list(list(val), [], encode_hook=None)


def _pack_tuple(val, encode_hook: EncodeHookType):
    if len(val) < 256:
        data = bytes([TAG_SMALL_TUPLE_EXT, len(val)])
    else:
        data = bytes([TAG_LARGE_TUPLE_EXT]) + util.to_u32(len(val))

    for item in val:
        data += term_to_binary_2(item, encode_hook)

    return data


def _pack_dict(val: dict, encode_hook: EncodeHookType) -> bytes:
    data = bytes([TAG_MAP_EXT]) + util.to_u32(len(val))
    for k in val.keys():
        data += term_to_binary_2(k, encode_hook)
        data += term_to_binary_2(val[k], encode_hook)
    return data


def _pack_int(val: int):
    if 0 <= val < 256:
        return bytes([TAG_SMALL_INT, val])
    size = val.bit_length()
    if size < 32:
        return bytes([TAG_INT]) + util.to_i32(val)
    # we get here we're packing smal or large big
    sign = 0 if 0 <= val else 1
    if sign:
        val *= -1  # switch to positive value
    size = int(size / 8) + 1
    if size < 256:
        hdr = bytes([TAG_SMALL_BIG_EXT, size, sign])
    else:
        hdr = bytes([TAG_LARGE_BIG_EXT]) + util.to_u32(size) + bytes([sign])

    data = val.to_bytes(size, 'little')
    return hdr + data


# TODO: maybe move this into atom class
def _pack_atom(text: str) -> bytes:
    atom_bytes = bytes(text, "utf8")
    if len(atom_bytes) < 256:
        return bytes([TAG_SMALL_ATOM_UTF8_EXT, len(atom_bytes)]) + atom_bytes
    return bytes([TAG_ATOM_UTF8_EXT]) + util.to_u16(len(atom_bytes)) + atom_bytes


# TODO: maybe move this into pid class
def _pack_pid(val) -> bytes:
    data = bytes([TAG_NEW_PID_EXT]) + \
           _pack_atom(val.node_name_) + \
           util.to_u32(val.id_) + \
           util.to_u32(val.serial_) + \
           util.to_u32(val.creation_)
    return data


# TODO: maybe move this into ref class
def _pack_ref(val) -> bytes:
    data = bytes([TAG_NEWER_REF_EXT]) \
           + util.to_u16(len(val.id_) // 4) \
           + _pack_atom(val.node_name_) \
           + util.to_u32(val.creation_) \
           + val.id_
    return data


def _is_a_simple_object(obj):
    """ Check whether a value can be simply encoded by term_to_binary and
        does not require class unwrapping by `serialize_object`.
    """
    return type(obj) == str \
        or type(obj) == list \
        or type(obj) == tuple \
        or type(obj) == dict \
        or type(obj) == int \
        or type(obj) == float \
        or isinstance(obj, Atom) \
        or isinstance(obj, Pid) \
        or isinstance(obj, Reference)


def generic_serialize_object(obj, cycle_detect: Optional[Set[int]] = None):
    """ Given an arbitraty Python object creates a tuple (ClassName, {Fields}).
        A fair effort is made to avoid infinite recursion on cyclic objects.
        :param obj: Arbitrary object to encode
        :param cycle_detect: A set with ids of object, for cycle detection
        :return: A pair of result: (ClassName :: bytes(), Fields :: {bytes(), _})
            or None, and a CycleDetect value
    """
    if cycle_detect is None:
        cycle_detect = set()

    # if cyclic encoding detected, ignore this value
    if id(obj) in cycle_detect:
        return None, cycle_detect

    cycle_detect.add(id(obj))

    object_name = type(obj).__name__
    fields = {}
    for key in obj.__dict__:
        val = getattr(obj, key)
        if not callable(val) and not key.startswith("_"):
            if _is_a_simple_object(val):
                fields[bytes(key, "latin1")] = val
            else:
                (ser, cycle_detect) = generic_serialize_object(val, cycle_detect=cycle_detect)
                fields[bytes(key, "latin1")] = ser

    return (bytes(object_name, "latin1"), fields), cycle_detect


def _pack_str(val):
    str_bytes = bytes(val, "utf8")
    len_str_bytes = len(str_bytes)
    len_val = len(val)

    if _can_be_a_bytestring(val) and len_str_bytes <= 65535:
        # same length as byte length
        header = bytes([TAG_STRING_EXT]) + util.to_u16(len_str_bytes)
        return header + str_bytes
    else:
        # contains unicode characters! must be encoded as a list of ints
        header = bytes([TAG_LIST_EXT]) + util.to_u32(len_val)
        elements = [_pack_int(ord(ch)) for ch in val]
        return header + b''.join(elements) + bytes([TAG_NIL_EXT])


def _can_be_a_bytestring(val: str) -> bool:
    i = 0
    for c in val:
        if i > 255 or ord(c) > 255:
            return False
    return True


def _pack_float(val: float) -> bytes:
    if not math.isfinite(val):
        raise PyCodecError("Float value %s is not finite" % val)
    return bytes([TAG_NEW_FLOAT_EXT]) + struct.pack(">d", val)


def _pack_binary(data, last_byte_bits):
    if last_byte_bits == 8:
        return bytes([TAG_BINARY_EXT]) + util.to_u32(len(data)) + data

    return bytes([TAG_BIT_BINARY_EXT]) + util.to_u32(len(data)) + \
        bytes([last_byte_bits]) + data


def term_to_binary_2(val: Any, encode_hook: EncodeHookType) -> bytes:
    """ Erlang lists are decoded into term.List object, whose ``elements_``
        field contains the data, ``tail_`` field has the optional tail and a
        helper function exists to assist with extracting an unicode string.

        :param encode_hook: None or a dict with key value pairs (t,v) where t
            is a python type (as string, i.e. 'int' not int) and v a callable
            operating on an object of type t.
            Additionally, t may be 'catch_all' and v a callback which returns a
            representation for unknown object types.
        :param val: Almost any Python value
        :return: bytes object with encoded data, but without a 131 header byte.
            None will be encoded as such and becomes Atom('undefined').
    """
    type_name_ref = type(val).__name__
    if encode_hook is not None and type_name_ref in encode_hook:
        hook_fn = encode_hook.get(type_name_ref)
        if hook_fn is not None:
            val = hook_fn(val)
        else:
            raise PyCodecError(f'term_to_binary: No hook function for type {type_name_ref}')

    type_val = type(val)
    if type_val == int:
        return _pack_int(val)

    elif type_val == float:
        return _pack_float(val)

    elif type_val == str:
        return _pack_str(val)

    elif type_val == bool:
        return _pack_atom("true") if val else _pack_atom("false")

    elif type_val == list:
        return _pack_list(val, [], encode_hook)

    elif type_val == tuple:
        return _pack_tuple(val, encode_hook)

    elif type_val == dict:
        return _pack_dict(val, encode_hook)

    elif val is None:
        return _pack_atom('undefined')

    elif isinstance(val, Atom):
        return _pack_atom(val)

    elif isinstance(val, ImproperList):
        return _pack_list(val._elements, val._tail, encode_hook)

    elif isinstance(val, Pid):
        return _pack_pid(val)

    elif isinstance(val, Reference):
        return _pack_ref(val)

    elif type_val == bytes:
        return _pack_binary(val, 8)

    elif isinstance(val, BitString):
        return _pack_binary(val.value_, val.last_byte_bits_)

    # Check if options had encode_hook which is not None.
    # Otherwise check if value class has a __etf__ member which is used instead.
    # Otherwise encode as a tuple (Atom('ClassName), dir(value))
    catch_all = None
    if encode_hook is not None:
        catch_all = encode_hook.get('catch_all', None)
    if catch_all is None:
        catch_all = getattr(val, "__etf__", None)
        if catch_all is None:
            ser, _ = generic_serialize_object(val)
            return term_to_binary_2(ser, encode_hook)
        else:
            return term_to_binary_2(catch_all(), encode_hook)
    else:
        return term_to_binary_2(catch_all(val), encode_hook)


def term_to_binary(val, opt: Optional[dict] = None) -> bytes:
    """ Prepend the 131 header byte to encoded data.
        :param val the value to encode
        :param opt:
            None or a dict with key value pairs (t,v) where t
            is a python type (as string, i.e. 'int' not int) and v a callable
            operating on an object of type t.
            Additionally, t may be 'catch_all' and v a callback which returns a
            representation for unknown object types.
        :return:
            None will be encoded as such and becomes Atom('undefined').
    """
    if opt is None:
        opt = {}
    encode_hook = opt.get("encode_hook", None)

    return bytes([ETF_VERSION_TAG]) + term_to_binary_2(val, encode_hook)


__all__ = ['binary_to_term', 'binary_to_term_2',
           'term_to_binary', 'term_to_binary_2',
           'PyCodecError',
           'generic_serialize_object']
