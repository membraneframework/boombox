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

from term.basetypes import BaseTerm, Term

ATOM_MARKER = "pyrlang.Atom"


class Atom(str, BaseTerm):
    """ Stores a string decoded from Erlang atom. Encodes back to atom.
        Beware this is equivalent to a Python string, when using this as a dict key:

            {Atom('foo'): 1, 'foo': 2} == {'foo': 2}
    """

    def __repr__(self):
        the_repr = super(Atom, self).__repr__()
        return f'Atom({the_repr})'

    @staticmethod
    def from_string_or_atom(s: Term) -> 'Atom':
        """ Create an Atom from a string or return unchanged if it was an atom. """
        return s if isinstance(s, Atom) else Atom(s)


class StrictAtom(Atom):
    """
    Stores a string decoded from Erlang atom. Encodes back to atom.

    Can serve as a Python dictionary key besides str with same content:

        {StrictAtom('foo'): 1, 'foo': 2} == {StrictAtom('foo'): 1, 'foo': 2}
    """

    def __repr__(self) -> str:
        the_repr = super(StrictAtom, self).__repr__()
        return f"Strict{the_repr}"

    def __str__(self):
        return self.__repr__()

    def __hash__(self):
        return hash((ATOM_MARKER, super(StrictAtom, self).__hash__()))
