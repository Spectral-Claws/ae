/**
 * Wrapper for long integer multiplication / division operands
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.math.longmul;

import std.traits;

import ae.utils.math;

struct LongInt(uint bits, bool signed)
{
	TypeForBits!bits low;
	static if (signed)
		Signed!(TypeForBits!bits) high;
	else
		TypeForBits!bits high;
}

alias LongInt(T) = LongInt!(T.sizeof * 8, isSigned!T);

alias Cent = LongInt!long;
alias UCent = LongInt!ulong;

version (X86)
	version = Intel;
else
version (X86_64)
	version = Intel;

version (Intel)
{
	enum x86RegSizePrefix(T) =
		T.sizeof == 2 ? "" :
		T.sizeof == 4 ? "E" :
		T.sizeof == 8 ? "R" :
		"?"; // force syntax error

	enum x86SignedOpPrefix(T) = isSigned!T ? "i" : "";
}

LongInt!T longMul(T)(T a, T b)
if (is(T : long) && T.sizeof >= 2)
{
	T low = void, high = void;
	version (Intel)
		mixin(`
			asm
			{
				mov `~x86RegSizePrefix!T~`AX, a;
				`~x86SignedOpPrefix!T~`mul b;
				mov low, `~x86RegSizePrefix!T~`AX;
				mov high, `~x86RegSizePrefix!T~`DX;
			}
		`);
	else
		static assert(false, "Not implemented on this architecture");
	return typeof(return)(low, high);
}

unittest
{
	assert(longMul(1, 1) == LongInt!int(1, 0));
	assert(longMul(1, 2) == LongInt!int(2, 0));
	assert(longMul(0x1_0000, 0x1_0000) == LongInt!int(0, 1));

	assert(longMul(short(1), short(1)) == LongInt!short(1, 0));
	assert(longMul(short(0x100), short(0x100)) == LongInt!short(0, 1));

	assert(longMul(short(1), short(-1)) == LongInt!short(cast(ushort)-1, -1));
	assert(longMul(ushort(1), cast(ushort)-1) == LongInt!ushort(cast(ushort)-1, 0));

	version(X86_64)
	{
		assert(longMul(1L, 1L) == LongInt!long(1, 0));
		assert(longMul(0x1_0000_0000L, 0x1_0000_0000L) == LongInt!long(0, 1));
	}
}

struct DivResult(T) { T quotient, remainder; }

DivResult!T longDiv(T, L)(L a, T b)
if (is(T : long) && T.sizeof >= 2 && is(L == LongInt!T))
{
	auto low = a.low;
	auto high = a.high;
	T quotient = void;
	T remainder = void;
	version (Intel)
		mixin(`
			asm
			{
				mov `~x86RegSizePrefix!T~`AX, low;
				mov `~x86RegSizePrefix!T~`DX, high;
				`~x86SignedOpPrefix!T~`div b;
				mov quotient, `~x86RegSizePrefix!T~`AX;
				mov remainder, `~x86RegSizePrefix!T~`DX;
			}
		`);
	else
		static assert(false, "Not implemented on this architecture");
	return typeof(return)(quotient, remainder);
}

unittest
{
	assert(longDiv(LongInt!int(1, 0), 1) == DivResult!int(1, 0));
	assert(longDiv(LongInt!int(5, 0), 2) == DivResult!int(2, 1));
	assert(longDiv(LongInt!int(0, 1), 0x1_0000) == DivResult!int(0x1_0000, 0));

	assert(longDiv(LongInt!short(1, 0), short(1)) == DivResult!short(1, 0));
	assert(longDiv(LongInt!short(0, 1), short(0x100)) == DivResult!short(0x100, 0));

	assert(longDiv(LongInt!short(cast(ushort)-1, -1), short(-1)) == DivResult!short(1));
	assert(longDiv(LongInt!ushort(cast(ushort)-1, 0), cast(ushort)-1) == DivResult!ushort(1));

	version(X86_64)
	{
		assert(longDiv(LongInt!long(1, 0), 1L) == DivResult!long(1));
		assert(longDiv(LongInt!long(0, 1), 0x1_0000_0000L) == DivResult!long(0x1_0000_0000));
	}
}
