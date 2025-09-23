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

""" Implement shared pieces of Erlang node negotiation and dist_proto
    protocol
"""

DIST_VSN_MAX = 6  # optional since OTP-23, made mandatory in OTP-25
DIST_VSN_MIN = 5  # nodes older than OTP-23 down to ancient R6B

DIST_VSN_PAIR = (DIST_VSN_MAX, DIST_VSN_MIN)
" Supported dist_proto protocol version (MAX,MIN). "


def dist_version_check(max_min: tuple) -> bool:
    """ Check pair of versions against versions which are supported by us

        :type max_min: tuple(int, int)
        :param max_min: (Max, Min) version pair for peer-supported dist version
    """
    return DIST_VSN_MIN <= max_min[0] and max_min[1] <= DIST_VSN_MAX # do ranges overlap?


def check_valid_dist_version(dist_vsn: int) -> bool:
    """
    Check that the version is supported
    :param dist_vsn: int
    :return: True if ok
    """
    return DIST_VSN_MIN <= dist_vsn <= DIST_VSN_MAX

# __all__ = ['DIST_VSN_MAX', 'DIST_VSN_MIN', 'DIST_VSN_PAIR']
