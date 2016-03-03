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

module gtd.GirPackage;

import std.algorithm;
import std.array: empty;
import std.file;
import std.path;
import std.string : splitLines, strip, split;
import std.uni;
import std.stdio;

import gtd.GirAlias;
import gtd.GirEnum;
import gtd.GirFunction;
import gtd.GirStruct;
import gtd.GirWrapper;
import gtd.IndentedStringBuilder;
import gtd.XML;
import gtd.LinkedHasMap: Map = LinkedHashMap;

class GirPackage
{
	string name;
	string cTypePrefix;
	string srcDir;
	string bindDir;
	GirWrapper wrapper;

	string[] publicImports;
	string[] lookupAliases;     /// Aliases defined in the lookupfile.
	string[] lookupEnums;       /// Enums defined in the lookupfile.
	string[] lookupStructs;     /// Structs defined in the lookupfile.
	string[] lookupFuncts;      /// Functions defined in the lookupfile.
	string[] lookupConstants;   /// Constants defined in the lookupfile.
	
	static GirPackage[string] namespaces;

	Map!(string, GirAlias)    collectedAliases; /// Aliases defined in the gir file.
	Map!(string, GirEnum)     collectedEnums;   /// Enums defined in the gir file.
	Map!(string, GirStruct)   collectedStructs;
	Map!(string, GirFunction) collectedCallbacks;
	Map!(string, GirFunction) collectedFunctions;
	GirEnum stockIDs;           /// The StockID enum (Deprecated).
	GirEnum GdkKeys;            /// The GdkKey enum.

	public this(string pack, GirWrapper wrapper, string srcDir, string bindDir)
	{
		this.name = pack;
		this.wrapper = wrapper;
		this.srcDir = srcDir;
		this.bindDir = bindDir;
		this.stockIDs = new GirEnum(wrapper, this);
		this.GdkKeys  = new GirEnum(wrapper, this);

		try
		{
			if ( !exists(buildPath(wrapper.outputRoot, srcDir, bindDir)) )
				mkdirRecurse(buildPath(wrapper.outputRoot, srcDir, bindDir));
		}
		catch (Exception)
		{
			throw new Exception("Failed to create directory: "~ buildPath(wrapper.outputRoot, srcDir, bindDir));
		}

		try
		{
			if ( !exists(buildPath(wrapper.outputRoot, srcDir, pack)) )
				mkdirRecurse(buildPath(wrapper.outputRoot, srcDir, pack));
		}
		catch (Exception)
		{
			throw new Exception("Failed to create directory: "~ buildPath(wrapper.outputRoot, srcDir, pack));
		}

		publicImports ~= bindDir ~"."~ pack;
	}

	void parseGIR(string girFile)
	{
		if ( !isAbsolute(girFile) )
			girFile = buildNormalizedPath("/usr/share/gir-1.0", girFile);

		auto reader = new XMLReader!string(readText(girFile), girFile);

		while ( !reader.empty && reader.front.value != "repository" )
			reader.popFront();

		reader.popFront();

		while ( !reader.empty && reader.front.value == "include" )
		{
			//TODO: parse imports.

			reader.popFront();
		}

		while ( !reader.empty && reader.front.value != "namespace" )
			reader.popFront();

		namespaces[reader.front.attributes["name"]] = this;
		cTypePrefix = reader.front.attributes["c:identifier-prefixes"];

		reader.popFront();

		while ( !reader.empty && !reader.endTag("namespace") )
		{
			if ( reader.front.type == XMLNodeType.EndTag )
			{
				reader.popFront();
				continue;
			}

			switch (reader.front.value)
			{
				case "alias":
					auto giAlias = new GirAlias(wrapper);
					giAlias.parse(reader);

					if ( giAlias.cType == "GType" )
						break;

					collectedAliases[giAlias.name] = giAlias;
					break;
				case "glib:boxed":
					reader.skipTag();
					break;
				case "bitfield":
				case "enumeration":
					auto giEnum = new GirEnum(wrapper, this);
					giEnum.parse(reader);
					collectedEnums[giEnum.name] = giEnum;
					break;
				case "class":
				case "interface":
				case "record":
				case "union":
					auto giStruct = new GirStruct(wrapper, this);
					giStruct.parse(reader);

					//Workaround: Dont overwrite the regular pango classes.
					if ( giStruct.cType.among("PangoCairoFont", "PangoCairoFontMap") )
					{
						collectedStructs["FcFontMap"].merge(giStruct);
						break;
					}

					collectedStructs[giStruct.name] = giStruct;

					if ( name == "pango" )
						giStruct.name = "Pg"~giStruct.name;
					break;
				case "callback":
					GirFunction callback = new GirFunction(wrapper, null);
					callback.parse(reader);
					collectedCallbacks[callback.name] = callback;
					break;
				case "constant":
					parseConstant(reader);
					break;
				case "function":
					parseFunction(reader);
					break;
				default:
					throw new XMLException(reader, "Unexpected tag: "~ reader.front.value ~" in GirPackage: "~ name);
			}
			reader.popFront();
		}
	}

	void parseConstant(T)(XMLReader!T reader)
	{
		if ( reader.front.attributes["name"].startsWith("STOCK_") )
		{
			GirEnumMember member = GirEnumMember(wrapper);
			member.parse(reader);
			member.name = member.name[6..$];

			stockIDs.members ~= member;
			return;
		}
		else if ( reader.front.attributes["c:type"].startsWith("GDK_KEY_") )
		{
			GirEnumMember member = GirEnumMember(wrapper);
			member.parse(reader);
			member.name = "GDK_"~ member.name[4..$];

			GdkKeys.members ~= member;
			return;
		}

		//TODO: other constants.
		reader.skipTag();
	}

	void parseFunction(T)(XMLReader!T reader)
	{
		GirFunction funct = new GirFunction(wrapper, null);
		funct.parse(reader);
		collectedFunctions[funct.name] = funct;
	}

	GirStruct getStruct(string name)
	{
		GirPackage pack = this;

		if ( name.canFind(".") )
		{
			string[] vals = name.split(".");

			if ( vals[0] !in namespaces )
				return null;

			pack = namespaces[vals[0]];
			name = vals[1];
		}
		return pack.collectedStructs.get(name, pack.collectedStructs.get("lookup"~name, null));
	}

	GirEnum getEnum(string name)
	{
		GirPackage pack = this;

		if ( name.canFind(".") )
		{
			string[] vals = name.split(".");

			if ( vals[0] !in namespaces )
				return null;

			pack = namespaces[vals[0]];
			name = vals[1];
		}
		return pack.collectedEnums.get(name, null);
	}

	void writeClasses()
	{
		foreach ( strct; collectedStructs )
			strct.writeClass();
	}

	void writeTypes()
	{
		string buff = wrapper.licence;
		auto indenter = new IndentedStringBuilder();

		buff ~= "module "~ bindDir ~"."~ name ~"types;\n\n";

		buff ~= indenter.format(lookupAliases);
		foreach ( a; collectedAliases )
		{
			buff ~= "\n";
			buff ~= indenter.format(a.getAliasDeclaration());
		}

		buff ~= indenter.format(lookupEnums);
		foreach ( e; collectedEnums )
		{
			buff ~= "\n";
			buff ~= indenter.format(e.getEnumDeclaration());
		}

		buff ~= indenter.format(lookupStructs);
		foreach ( s; collectedStructs )
		{
			if ( s.noExternal || s.noDecleration )
				continue;

			buff ~= "\n";
			buff ~= indenter.format(s.getStructDeclaration());
		}

		buff ~= indenter.format(lookupFuncts);
		foreach ( f; collectedCallbacks )
		{
			buff ~= "\n";
			buff ~= indenter.format(f.getCallbackDeclaration());
		}

		buff ~= indenter.format(lookupConstants);
		if ( stockIDs.members !is null )
		{
			stockIDs.cName = "StockID";
			stockIDs.doc = "StockIds";
			buff ~= "\n";
			buff ~= indenter.format(stockIDs.getEnumDeclaration());
		}

		if ( GdkKeys.members !is null )
			writeGdkKeys();

		std.file.write(buildPath(wrapper.outputRoot, srcDir, bindDir, name ~"types.d"), buff);
	}

	void writeGdkKeys()
	{
		string buff = wrapper.licence;

		buff ~= "module "~ name ~".Keysyms;\n\n";

		buff ~= "/**\n";
		buff ~= " * GdkKeysyms.\n";
		buff ~= " */\n";
		buff ~= "public enum GdkKeysyms\n";
		buff ~= "{\n";

		foreach ( member; GdkKeys.members )
		{
			buff ~= "\t"~ tokenToGtkD(member.name, wrapper.aliasses, false) ~" = "~ member.value ~",\n";
		}

		buff ~= "}\n";

		std.file.write(buildPath(wrapper.outputRoot, srcDir, name, "Keysyms.d"), buff);
	}

	void writeLoaderTable()
	{
		string buff = wrapper.licence;

		buff ~= "module "~ bindDir ~"."~ name ~";\n\n";
		buff ~= "import std.stdio;\n";
		buff ~= "import "~ bindDir ~"."~ name ~"types;\n";

		buff ~= "import gi.gobjecttypes;\n";
		if ( name == "gdk" || name == "pango" )
			buff ~= "import gi.cairotypes;\n";


		// FIXME MAK
		//buff ~= "import gi.Loader;\n\n"
		//	~ "shared static this()\n"
		//	~ "{";

		//foreach ( strct; collectedStructs )
		//{
		//	if ( strct.functions.empty || strct.noExternal )
		//		continue;

		//	buff ~= "\n\t// "~ name ~"."~ strct.name ~"\n\n";

		//	foreach ( funct; strct.functions )
		//	{
		//		if ( funct.type == GirFunctionType.Callback || funct.type == GirFunctionType.Signal || funct.name.empty )
		//			continue;

		//		buff ~= "\tLinker.link("~ funct.cType ~", \""~ funct.cType ~"\", "~ getLibrary(funct.cType) ~");\n";
		//	}
		//}

		buff ~= "\n\n"
			~ "__gshared extern(C)\n"
			~ "{\n";

		foreach ( strct; collectedStructs )
		{
			if ( strct.functions.empty || strct.noExternal )
				continue;

			buff ~= "\n\t// "~ name ~"."~ strct.name ~"\n\n";

			foreach ( funct; strct.functions )
			{
				if ( funct.type == GirFunctionType.Callback || funct.type == GirFunctionType.Signal || funct.name.empty )
					continue;

				buff ~= "\t"~ funct.getExternal() ~"\n";
			}
		}

		buff ~= "}\n\n";

		// FIXME MAK
		//foreach ( strct; collectedStructs )
		//{
		//	if ( strct.functions.empty || strct.noExternal )
		//		continue;

		//	buff ~= "\n// "~ name ~"."~ strct.name ~"\n\n";

		//	foreach ( funct; strct.functions )
		//	{
		//		if ( funct.type == GirFunctionType.Callback || funct.type == GirFunctionType.Signal || funct.name.empty )
		//			continue;

		//		if (name == "glgdk")
		//			buff ~= "alias glc_"~ funct.cType ~" "~ funct.cType ~";\n";
		//		else
		//			buff ~= "alias c_"~ funct.cType ~" "~ funct.cType ~";\n";
		//	}
		//}

		std.file.write(buildPath(wrapper.outputRoot, srcDir, bindDir, name ~".d"), buff);
	}

	private string getLibrary(string funct)
	{
		string library = "LIBRARY."~ name.toUpper();

		if ( startsWith(funct, "gdk") && !startsWith(funct, "gdk_gl") )
			return library ~ ", LIBRARY.GDKPIXBUF";
		else if	( startsWith(funct, "pango_cairo") )
			return library ~ ", LIBRARY.PANGOCAIRO";
		else if	( startsWith(funct, "g_module") )
			return library ~ ", LIBRARY.GMODULE";
		else
			return library;
	}
}