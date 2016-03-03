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

module gtd.GirAlias;

import std.string : splitLines, strip;

import gtd.GirType;
import gtd.GirWrapper;
import gtd.XML;

final class GirAlias
{
	string name;
	string cType;
	string doc;

	GirType baseType;
	GirWrapper wrapper;

	this(GirWrapper wrapper)
	{
		this.wrapper = wrapper;
	}

	void parse(T)(XMLReader!T reader)
	{
		name = reader.front.attributes["name"];
		cType = reader.front.attributes["c:type"];

		reader.popFront();

		while( !reader.empty && !reader.endTag("alias") )
		{
			switch(reader.front.value)
			{
				case "type":
					baseType = new GirType(wrapper);
					baseType.parse(reader);
					break;
				case "doc":
					reader.popFront();
					doc ~= reader.front.value;
					reader.popFront();
					break;
				case "doc-deprecated":
					reader.popFront();
					doc ~= "\n\nDeprecated: "~ reader.front.value;
					reader.popFront();
					break;
				default:
					throw new XMLException(reader, "Unexpected tag: "~ reader.front.value ~" in GirAlias: "~ name);
			}
			reader.popFront();
		}
	}

	string[] getAliasDeclaration()
	{
		string[] buff;
		if ( doc !is null && wrapper.includeComments )
		{
			buff ~= "/**";
			foreach ( line; doc.splitLines() )
				buff ~= " * "~ line.strip();
			buff ~= " */";
		}

		buff ~= "public alias "~ tokenToGtkD(baseType.cType, wrapper.aliasses) ~" "~ tokenToGtkD(cType, wrapper.aliasses) ~";";

		return buff;
	}
}