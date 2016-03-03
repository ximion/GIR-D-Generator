/*
 * This file is part of gir-d-generator.
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This software is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

module gtd.LinkedHasMap;

import core.memory;

/**
 * An hash map that allows iteration in the insertion-order.
 */
struct LinkedHashMap(Key, Value)
{
	static struct Node
	{
		Value val;
		Key key;
		Node* next;
		Node* previous;
	}

	private Node*[Key] data;
	private Node* front;
	private Node* back;

	/**
	 * Looks up key, if it exsists returns the corresponding value
	 * else evaluates and returns defaultValue.
	 */
	inout(Value) get(Key key, lazy inout(Value) defaultValue = Value.init) inout pure @safe
	{
		if ( key !in data )
			return defaultValue;

		return data[key].val;
	}

	/**
	 * remove(key) does nothing if the given key does not exist and returns false.
	 * If the given key does exist, it removes it from the HashMap and returns true.
	 */
	bool remove(Key key) pure nothrow @trusted
	{
		Node** nodeP = key in data;

		if ( nodeP is null )
			return false;

		Node* node = *nodeP;

		if ( node is front )
			front = node.next;
		if ( node is back )
			back = node.previous;

		if ( node.previous )
			node.previous.next = node.next;
		if ( node.next )
			node.next.previous = node.previous;

		data.remove(key);
		GC.free(node);

		return true;
	}

	/**
	 * Removes all contents from the LinkedHashMap
	 */
	void clear() pure nothrow @trusted
	{
		Node* node = front;
		Node* previous;

		while ( node !is null )
		{
			previous = node;
			node = node.next;

			GC.free(previous);
		}

		data.destroy();
		front = null;
		back = null;
	}

	/**
	 * Returns: the number of values in the LinkedHasMap.
	 */
	@property size_t length() nothrow pure const @trusted
	{
		return data.length;
	}

	/**
	 * Returns: true if the LinkedHasmap has no elements.
	 */
	@property bool empty() nothrow pure const @safe
	{
		return front is null;
	}

	/**
	 * Indexing operators yield or modify the value at a specified index.
	 */
	inout(Value) opIndex(Key key) inout pure @safe
	{
		return data[key].val;
	}

	/// ditto
	void opIndexAssign(Value value, Key key) @safe
	{
		Node* node;

		if ( key !in data )
		{
			node = new Node;
		}
		else
		{
			node = data[key];
			node.val = value;
			return;
		}

		node.val = value;
		node.key = key;

		data[key] = node;

		if ( front is null )
		{
			front = node;
			back = node;
			return;
		}

		node.previous = back;
		back.next = node;
		back = node;
	}

	/// ditto
	Value opIndexUnary(string op)(Key key) @safe
	{
		Node* node = data[key];
		return mixin(op ~"node.val;");
	}

	/// ditto
	Value opIndexOpAssign(string op)(Value v, Key key) @safe
	{
		Node* node = data[key];
		return mixin("node.val" ~ op ~ "=v");
	}

	/**
	 * in operator. Check to see if the given element exists in the container.
	 */
	inout(Value)* opBinaryRight(string op)(Key key) inout nothrow pure @safe
	if (op == "in")
	{
		inout(Node*)* node = key in data;

		if ( node is null )
			return null;

		return &((*node).val);
	}

	/**
	 * foreach iteration uses opApply.
	 */
	int opApply(scope int delegate(ref Value) dg)
	{
		Node* node = front;

		while ( node !is null )
		{
			int result = dg(node.val);
			if ( result )
				return result;

			node = node.next;
		}

		return 0;
	}

	/// ditto
	int opApply(scope int delegate(ref Key, ref Value) dg)
	{
		Node* node = front;

		while ( node !is null )
		{
			int result = dg(node.key, node.val);
			if ( result )
				return result;

			node = node.next;
		}

		return 0;
	}

	/**
	 * Returns: true if this and that are equal.
	 */
	bool opEquals(inout typeof(this) that) inout nothrow pure @safe
	{
		return data == that.data;
	}

	/**
	 * Returns: An dynamic array, the elements of which are the keys in the LinkedHashmap.
	 */
	@property inout(Key)[] keys() inout @safe
	{
		inout(Key)[] k;

		inout(Node)* node = front;

		while ( node !is null )
		{
			k ~= node.key;
			node = node.next;
		}

		return k;
	}

	/**
	 * Returns: An dynamic array, the elements of which are the values in the LinkedHashmap.
	 */
	@property inout(Value)[] values() inout @safe
	{
		inout(Value)[] v;

		inout(Node)* node = front;

		while ( node !is null )
		{
			v ~= node.val;
			node = node.next;
		}

		return v;
	}

	/**
	 * Reorganizes the LinkedHashMap in place so that lookups are more efficient,
	 * rehash is effective when, for example, the program is done loading up
	 * a symbol table and now needs fast lookups in it.
	 */
	void rehash() @trusted
	{
		data = data.rehash();
	}

	/**
	 * Create a new LinkedHashMap of the same size and copy the contents of the LinkedHashMap into it.
	 */
	LinkedHashMap!(Key, Value) dub() @safe
	{
		LinkedHashMap!(Key, Value) copy;
		Node* node = front;

		while ( node !is null )
		{
			copy[node.key] = node.val;
			node = node.next;
		}

		return copy;
	}

	/**
	 * Returns a delegate suitable for use as a ForeachAggregate to
	 * a ForeachStatement which will iterate over the keys of the LinkedHashMap.
	 */
	@property auto byKey() pure nothrow @safe
	{
		static struct KeyRange
		{
			Node* node;

			this(Node* node) pure nothrow @safe
			{
				this.node = node;
			}

			@property Key front() pure nothrow @safe
			{
				return node.key;
			}

			void popFront() pure nothrow @safe
			{
				node = node.next;
			}

			@property bool empty() pure const nothrow @safe
			{
				return node is null;
			}
		}

		return KeyRange(front);
	}

	/**
	 * Returns a delegate suitable for use as a ForeachAggregate to
	 * a ForeachStatement which will iterate over the values of the LinkedHashMap.
	 */
	@property auto byValue() pure nothrow @safe
	{
		static struct ValueRange
		{
			Node* node;

			this(Node* node) pure nothrow @safe
			{
				this.node = node;
			}

			@property Value front() pure nothrow @safe
			{
				return node.val;
			}

			void popFront() pure nothrow @safe
			{
				node = node.next;
			}

			@property bool empty() pure const nothrow @safe
			{
				return node is null;
			}
		}

		return ValueRange(front);
	}
}