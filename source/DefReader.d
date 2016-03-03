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

module gtd.DefReader;

import std.algorithm;
import std.array;
import std.file;
import std.string : splitLines, strip, indexOf;

import gtd.WrapError;

public class DefReader
{
	string filename;
	string key;
	string value;

	int lineNumber;
	string[] lines;

	public this(string filename)
	{
		this.filename = filename;

		lines = readText(filename).splitLines();
		//Skip utf8 BOM.
		lines[0].skipOver(x"efbbbf");

		this.popFront();
	}

	public void popFront()
	{
		string line;

		if ( !lines.empty )
		{
			line = lines.front.strip();
			lines.popFront();
			lineNumber++;

			while ( !lines.empty && ( line.empty || line.startsWith("#") ) )
			{
				line = lines.front.strip();
				lines.popFront();
				lineNumber++;
			}
		}

		if ( !line.empty && !line.startsWith("#") )
		{
			size_t index = line.indexOf(':');

			key   = line[0 .. max(index, 0)].strip();
			value = line[index +1 .. $].strip();
		}
		else
		{
			key.length = 0;
			value.length = 0;
		}
	}

	/**
	 * Gets the contends of a block value
	 */
	public string[] readBlock(string key = "")
	{
		string[] block;

		if ( key.empty )
			key = this.key;

		while ( !lines.empty )
		{
			if ( startsWith(lines.front.strip(), key) )
			{
				lines.popFront();
				lineNumber++;
				return block;
			}

			block ~= lines.front ~ '\n';
			lines.popFront();
			lineNumber++;
		}

		throw new WrapError(this, "Found EOF while expecting: \""~key~": end\"");
	}

	/**
	 * Gets the current value as a bool
	 */
	public @property bool valueBool()
	{
		return !!value.among("1", "ok", "OK", "Ok", "true", "TRUE", "True", "Y", "y", "yes", "YES", "Yes");
	}

	public @property bool empty()
	{
		return lines.empty && key.empty;
	}
}