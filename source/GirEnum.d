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

module gtd.GirEnum;

import std.algorithm;
import std.string : splitLines, strip, toUpper;

import gtd.GirPackage;
import gtd.GirWrapper;
import gtd.XML;

final class GirEnum
{
	string name;
	string cName;
	string libVersion;
	string doc;

	GirEnumMember[] members;
	GirWrapper wrapper;
	GirPackage pack;

	this(GirWrapper wrapper, GirPackage pack)
	{
		this.wrapper = wrapper;
		this.pack = pack;
	}

	void parse(T)(XMLReader!T reader)
	{
		name = reader.front.attributes["name"];
		cName = reader.front.attributes["c:type"];

		if ( "version" in reader.front.attributes )
			libVersion = reader.front.attributes["version"];
		reader.popFront();

		while ( !reader.empty && !reader.endTag("bitfield", "enumeration") )
		{
			switch (reader.front.value)
			{
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
				case "member":
					if ( reader.front.attributes["name"].startsWith("2bu", "2bi", "3bu") )
					{
						reader.skipTag();
						break;
					}

					GirEnumMember member = GirEnumMember(wrapper);
					member.parse(reader);
					members ~= member;
					break;
				case "function":
					//Skip these functions for now
					//as they are also availabe as global functions.
					//pack.parseFunction(reader);
					reader.skipTag();
					break;
				default:
					throw new XMLException(reader, "Unexpected tag: "~ reader.front.value ~" in GirEnum: "~ name);
			}
			reader.popFront();
		}
	}

	string[] getEnumDeclaration()
	{
		string[] buff;
		if ( doc !is null && wrapper.includeComments )
		{
			buff ~= "/**";
			foreach ( line; doc.splitLines() )
				buff ~= " * "~ line.strip();

			if ( libVersion )
			{
				buff ~= " *";
				buff ~= " * Since: "~ libVersion;
			}

			buff ~= " */";
		}

		buff ~= "public enum "~ cName ~(name.among("ParamFlags", "MessageType") ? " : uint" : "");
		buff ~= "{";

		foreach ( member; members )
		{
			buff ~= member.getEnumMemberDeclaration();
		}

		buff ~= "}";
		if ( name !is null && pack.name.among("glgdk", "glgtk") )
			buff ~= "alias "~ cName ~" GL"~ name ~";";
		else if ( name !is null && pack.name != "pango" )
			buff ~= "alias "~ cName ~" "~ name ~";";

		return buff;
	}
}

struct GirEnumMember
{
	string name;
	string value;
	string doc;

	GirWrapper wrapper;

	@disable this();

	this(GirWrapper wrapper)
	{
		this.wrapper = wrapper;
	}

	void parse(T)(XMLReader!T reader)
	{
		name = reader.front.attributes["name"];
		value = reader.front.attributes["value"];

		if ( reader.front.type == XMLNodeType.EmptyTag )
			return;

		reader.popFront();

		while ( !reader.empty && !reader.endTag("member", "constant") )
		{
			switch (reader.front.value)
			{
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
				case "type":
					if ( reader.front.attributes["name"] == "utf8" )
						value = "\""~ value ~"\"";
					break;
				default:
					throw new XMLException(reader, "Unexpected tag: "~ reader.front.value ~" in GirEnumMember: "~ name);
			}
			reader.popFront();
		}
	}

	string[] getEnumMemberDeclaration()
	{
		string[] buff;
		if ( doc !is null && wrapper.includeComments )
		{
			buff ~= "/**";
			foreach ( line; doc.splitLines() )
				buff ~= " * "~ line.strip();
			buff ~= " */";
		}

		buff ~= tokenToGtkD(name.toUpper(), wrapper.aliasses, false) ~" = "~ value ~",";

		return buff;
	}
}