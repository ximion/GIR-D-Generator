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

module gtd.GirStruct;

import std.algorithm: sort, uniq, endsWith;
import std.array : replace;
import std.conv;
import std.file : write;
import std.path: buildPath;
import std.uni: toUpper, toLower;
import std.range;
import std.string: capitalize, splitLines, strip, chomp;

import gtd.GirFunction;
import gtd.GirPackage;
import gtd.GirType;
import gtd.GirWrapper;
import gtd.XML;
import gtd.LinkedHasMap: Map = LinkedHashMap;
import gtd.IndentedStringBuilder;

enum GirStructType : string
{
	Class = "class",
	Interface = "interface",
	Record = "record",
	Union = "union"
}

final class GirStruct
{
	string name;
	GirStructType type;
	string doc;
	string cType;
	string parent;
	string libVersion;

	bool lookupClass = false;
	bool lookupInterface = false;
	bool lookupParent = false;  // is the parent set with the lookup file.
	bool noCode = false;
	bool noDecleration = false;
	bool noExternal = false;
	bool noNamespace = false;
	string[string] structWrap;
	string[string] aliases;
	string[] lookupCode;
	string[] lookupInterfaceCode;

	string[] implements;
	string[] imports;
	GirField[] fields;
	string[] virtualFunctions;
	Map!(string, GirFunction) functions;

	GirWrapper wrapper;
	GirPackage pack;
	GirStruct parentStruct;

	this(GirWrapper wrapper, GirPackage pack)
	{
		this.wrapper = wrapper;
		this.pack = pack;
	}

	GirStruct dup()
	{
		GirStruct copy = new GirStruct(wrapper, pack);

		foreach ( i, field; this.tupleof )
			copy.tupleof[i] = field;

		return copy;
	}

	void parse(T)(XMLReader!T reader)
	{
		name = reader.front.attributes["name"];
		type = cast(GirStructType)reader.front.value;

		if ( "c:type" in reader.front.attributes )
			cType = reader.front.attributes["c:type"];
		if ( "parent" in reader.front.attributes )
			parent = reader.front.attributes["parent"];
		if ( "version" in reader.front.attributes )
			libVersion = reader.front.attributes["version"];

		if ( !parent.empty )
		{
			if ( parent == "GObject.InitiallyUnowned" )
				parent = "GObject.Object";
			else if ( parent == "InitiallyUnowned" )
				parent = "Object";
		}

		if ( pack && pack.name != "glib" && "glib:get-type" in reader.front.attributes && reader.front.attributes["glib:get-type"].endsWith("_get_type") )
			functions["get_type"] = getTypeFunction(reader.front.attributes["glib:get-type"]);

		if ( reader.front.type == XMLNodeType.EmptyTag )
			return;

		reader.popFront();

		while( !reader.empty && !reader.endTag("class", "interface", "record", "union") )
		{
			switch(reader.front.value)
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
				case "field":
					GirField field = new GirField(wrapper);
					field.parse(reader);
					fields ~= field;
					break;
				case "record":
					GirField field = new GirField(wrapper);
					GirStruct strct = new GirStruct(wrapper, null);
					strct.parse(reader);
					strct.cType = strct.cType.toUpper()[0..1] ~ strct.cType[1 .. $];
					field.gtkStruct = strct;
					fields ~= field;
					break;
				case "union":
					GirField field = new GirField(wrapper);
					GirUnion uni = new GirUnion(wrapper);
					uni.parse(reader);
					field.gtkUnion = uni;
					fields ~= field;
					break;
				case "constructor":
				case "method":
				case "glib:signal":
					if ( type == GirStructType.Record )
						type = GirStructType.Class;
					goto case "function";
				case "function":
					GirFunction func = new GirFunction(wrapper, this);
					func.parse(reader);
					if ( func.type == GirFunctionType.Signal )
						functions[func.name~"-signal"] = func;
					else
						functions[func.name] = func;
					break;
				case "virtual-method":
					// Virtual methods in the gir file are mirrored
					// as regular methods, so we only collect whitch are virtual;
					virtualFunctions ~= reader.front.attributes["name"];
					reader.skipTag();
					break;
				case "implements":
					implements ~= reader.front.attributes["name"];
					break;
				case "prerequisite": // Determines whitch base class the implementor of an interface must implement.
				case "property":
					reader.skipTag();
					break;
				default:
					throw new XMLException(reader, "Unexpected tag: "~ reader.front.value ~" in GirStruct: "~ name);
			}

			reader.popFront();
		}

		foreach( func; virtualFunctions )
		{
			if ( auto vFunc = func in functions )
				vFunc.virtual = true;
		}

		if ( type == GirStructType.Union )
		{
			GirField field = new GirField(wrapper);
			GirUnion uni = new GirUnion(wrapper);
			uni.fields = fields;
			field.gtkUnion = uni;
			fields = [field];

			//special case for "_Value__data__union"
			if ( cType.empty )
				cType = name;

			type = GirStructType.Record;

			foreach ( funct; functions )
			{
				if ( funct.type != GirFunctionType.Function )
					type = GirStructType.Class;
			}
		}
	}

	string[] getStructDeclaration()
	{
		if ( noExternal || cType.empty )
			return null;

		string[] buff;

		if ( doc !is null && wrapper.includeComments && type == GirStructType.Record )
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

		if ( !fields.empty )
		{
			buff ~= "struct "~ tokenToGtkD(cType, wrapper.aliasses);
			buff ~= "{";
			buff ~= GirField.getFieldDeclarations(fields, wrapper);
			buff ~= "}";
		}
		else
		{
			buff ~= "struct "~ tokenToGtkD(cType, wrapper.aliasses) ~";";
		}

		return buff;
	}

	void writeClass()
	{
		bool[string] ctors;

		if ( noCode )
			return;

		if ( type == GirStructType.Record && !(lookupClass || lookupInterface) && (functions.empty && lookupCode.empty ) )
			return;

		parentStruct = pack.getStruct(parent);
		resolveImports();

		if ( type == GirStructType.Record && !(lookupClass || lookupInterface) )
		{
			writeDStruct();
			return;
		}

		if ( isInterface() )
			writeInterface();

		string buff = wrapper.licence;
		auto indenter = new IndentedStringBuilder();

		if ( isInterface() )
			buff ~= "module "~ pack.name ~"."~ name ~"T;\n\n";
		else
			buff ~= "module "~ pack.name ~"."~ name ~";\n\n";

		writeImports(buff, isInterface() );
		writeDocs(buff);

		if ( isInterface() )
			buff ~= "public template "~ name ~"T(TStruct)";
		else
			buff ~= "public class "~ name;

		if ( lookupParent && !parentStruct )
			buff ~= " : "~ parent;
		else if ( parentStruct && parentStruct.name != name )
			buff ~= " : "~ parentStruct.name;
		else if ( parentStruct )
			buff ~= " : "~ parentStruct.pack.name.capitalize() ~ parentStruct.name;

		bool first = !parentStruct;

		foreach ( interf; implements )
		{
			if ( parentStruct && parentStruct.implements.canFind(interf) )
				continue;

			// If the parentStruct is in an different package compare without package name.
			if ( parentStruct && interf.canFind(".") && parentStruct.implements.canFind(interf.split('.')[1]) )
				continue;

			GirStruct strct = pack.getStruct(interf);

			if ( strct && first )
			{
				buff ~= " :";
				first = false;
			}
			else if ( strct )
				buff ~= ",";

			if ( strct )
				buff ~= " "~ strct.name ~"IF";
		}

		buff ~= "\n";
		buff ~= indenter.format("{");

		if ( !cType.empty )
		{
			if ( !isInterface() )
			{
				buff ~= indenter.format("/** the main GObject struct */");
				buff ~= indenter.format("protected "~ cType ~"* "~ getHandleVar() ~";");
				buff ~= "\n";
			}
			buff ~= indenter.format("/** Get the main GObject struct */");
			buff ~= indenter.format("public "~ cType ~"* "~ getHandleFunc() ~"()");
			buff ~= indenter.format("{");

			if ( isInterface() )
				buff ~= indenter.format("return cast("~ cType ~"*)getStruct();");
			else
				buff ~= indenter.format("return "~ getHandleVar ~";");

			buff ~= indenter.format("}");
			buff ~= "\n";

			if ( !isInterface() )
			{
				buff ~= indenter.format("/** the main GObject struct as a void* */");

				if ( parentStruct )
					buff ~= indenter.format("protected override void* getStruct()");
				else
					buff ~= indenter.format("protected void* getStruct()");

				buff ~= indenter.format("{");
				buff ~= indenter.format("return cast(void*)"~ getHandleVar ~";");
				buff ~= indenter.format("}");
				buff ~= "\n";
			}

			if ( !isInterface() && cType != "GObject" && cType != "cairo_t" )
			{
				if ( parentStruct && pack.name != "cairo" )
				{
					buff ~= indenter.format("protected override void setStruct(GObject* obj)");
					buff ~= indenter.format("{");
					buff ~= indenter.format(getHandleVar ~" = cast("~ cType ~"*)obj;");
					buff ~= indenter.format("super.setStruct(obj);");
					buff ~= indenter.format("}");
					buff ~= "\n";
				}

				buff ~= indenter.format("/**");
				buff ~= indenter.format(" * Sets our main struct and passes it to the parent class.");
				buff ~= indenter.format(" */");

				if ( parentStruct && getAncestor().name == "ObjectG" )
					buff ~= indenter.format("public this ("~ cType ~"* "~ getHandleVar() ~", bool ownedRef = false)");
				else
					buff ~= indenter.format("public this ("~ cType ~"* "~ getHandleVar() ~")");

				buff ~= indenter.format("{");
				buff ~= indenter.format("this."~ getHandleVar() ~" = "~ getHandleVar() ~";");

				if ( parentStruct && getAncestor().name == "ObjectG" )
					buff ~= indenter.format("super(cast("~ parentStruct.cType ~"*)"~ getHandleVar() ~", ownedRef);");
				else if ( parentStruct )
					buff ~= indenter.format("super(cast("~ parentStruct.cType ~"*)"~ getHandleVar() ~");");

				buff ~= indenter.format("}");
				buff ~= "\n";
			}

			foreach ( interf; implements )
			{
				if ( parentStruct && parentStruct.implements.canFind(interf) )
					continue;

				if ( parentStruct && interf.canFind(".") && parentStruct.implements.canFind(interf.split('.')[1]) )
					continue;

				GirStruct strct = pack.getStruct(interf);

				if ( strct )
				{
					buff ~= indenter.format("// add the "~ strct.name ~" capabilities");
					buff ~= indenter.format("mixin "~ strct.name ~"T!("~ cType.chomp("*") ~");");
					buff ~= "\n";
				}
			}

		}

		if ( !lookupCode.empty )
		{
			buff ~= indenter.format(lookupCode);
			buff ~= "\n";

			buff ~= indenter.format(["/**", "*/"]);
		}

		bool firstSignal = true;

		foreach ( func; functions )
		{
			if ( func.noCode || func.isVariadic() || func.type == GirFunctionType.Callback )
				continue;

			if ( isInterface() && func.type == GirFunctionType.Constructor )
				continue;

			if ( func.type == GirFunctionType.Signal )
			{
				buff ~= "\n";

				if ( firstSignal )
				{
					buff ~= indenter.format("int[string] connectedSignals;");
					buff ~= "\n";
					firstSignal = false;
				}

				if ( isInterface() )
				{
					string[] prop;

					prop ~= func.getDelegateDecleration() ~"[] _on"~ func.getSignalName() ~"Listeners;";
					prop ~= "@property "~ func.getDelegateDecleration() ~"[] on"~ func.getSignalName() ~"Listeners()";
					prop ~= "{";
					prop ~= "return _on"~ func.getSignalName() ~"Listeners;";
					prop ~= "}";

					buff ~= indenter.format(prop);
				}
				else
				{
					buff ~= indenter.format(func.getDelegateDecleration() ~"[] on"~ func.getSignalName() ~"Listeners;");
				}

				buff ~= indenter.format(func.getAddListenerdeclaration());
				buff ~= indenter.format(func.getAddListenerBody());
				buff ~= indenter.format(func.getSignalCallback());

				foreach ( param; func.params )
				{
					if ( param.type.name.startsWith("Gdk.Event") && param.type.name != "Gdk.Event" )
					{
						buff ~= "\n";
						buff ~= indenter.format(getGenericEventSignal(func));

						break;
					}
				}
			}
			else
			{
				buff ~= "\n";
				buff ~= indenter.format(func.getDeclaration());
				buff ~= indenter.format("{");
				buff ~= indenter.format(func.getBody());
				buff ~= indenter.format("}");
			}
		}

		buff ~= indenter.format("}");

		if ( isInterface() )
			std.file.write(buildPath(wrapper.outputRoot, pack.srcDir, pack.name, name ~"T.d"), buff);
		else
			std.file.write(buildPath(wrapper.outputRoot, pack.srcDir, pack.name, name ~".d"), buff);
	}

	void writeInterface()
	{
		string buff = wrapper.licence;
		auto indenter = new IndentedStringBuilder();

		buff ~= "module "~ pack.name ~"."~ name ~"IF;\n\n";

		writeImports(buff);
		writeDocs(buff);

		buff ~= "public interface "~ name ~"IF";
		buff ~= indenter.format("{");

		if ( cType )
		{
			buff ~= indenter.format("/** Get the main GObject struct */");
			buff ~= indenter.format("public "~ cType ~"* "~ getHandleFunc() ~"();");
			buff ~= "\n";

			buff ~= indenter.format("/** the main GObject struct as a void* */");
			buff ~= indenter.format("protected void* getStruct();");
			buff ~= "\n";

			if ( !lookupInterfaceCode.empty )
			{
				buff ~= indenter.format(lookupInterfaceCode);
				buff ~= "\n";

				buff ~= indenter.format(["/**", "*/"]);
			}

			foreach ( func; functions )
			{
				if ( func.noCode || func.isVariadic() || func.type == GirFunctionType.Callback || func.type == GirFunctionType.Constructor )
					continue;

				if ( func.type == GirFunctionType.Signal )
				{
					buff ~= indenter.format("@property "~ func.getDelegateDecleration() ~"[] on"~ func.getSignalName() ~"Listeners();");
					string[] dec = func.getAddListenerdeclaration();
					dec[$-1] ~= ";";

					buff ~= indenter.format(dec);
					buff ~= "\n";
				}
				else
				{
					string[] dec = func.getDeclaration();
					dec[$-1] = dec[$-1].replace("override ", "");
					dec[$-1] ~= ";";

					buff ~= "\n";
					buff ~= indenter.format(dec);
				}
			}

			buff ~= indenter.format("}");
		}

		std.file.write(buildPath(wrapper.outputRoot, pack.srcDir, pack.name, name ~"IF.d"), buff);
	}

	void writeDStruct()
	{
		string buff = wrapper.licence;
		auto indenter = new IndentedStringBuilder();

		buff ~= "module "~ pack.name ~"."~ name ~";\n\n";

		writeImports(buff);
		writeDocs(buff);

		if ( !noNamespace )
		{
			buff ~= "public struct "~ name ~"\n";
			buff ~= indenter.format("{");
		}

		if ( !lookupCode.empty )
		{
			buff ~= indenter.format(lookupCode);
			buff ~= "\n";

			buff ~= indenter.format(["/**", "*/"]);
		}

		foreach ( func; functions )
		{
			if ( func.noCode || func.isVariadic() || !( func.type == GirFunctionType.Function || func.type == GirFunctionType.Method ) )
				continue;

			buff ~= "\n";
			buff ~= indenter.format(func.getDeclaration());
			buff ~= indenter.format("{");
			buff ~= indenter.format(func.getBody());
			buff ~= indenter.format("}");
		}

		if ( !noNamespace )
			buff ~= indenter.format("}");

		std.file.write(buildPath(wrapper.outputRoot, pack.srcDir, pack.name, name ~".d"), buff);
	}

	/**
	 * Return the variable name the c type is stored in.
	 */
	string getHandleVar()
	{
		if (cType.length == 0)
			return "";

		string p = to!string(toLower(cType[0]));
		if ( cType.endsWith("_t") )
		{
			return p ~ cType[1 .. $ - 2];
		} else {
			return p ~ cType[1 .. $];
		}
	}

	/**
	 * Returns the name of the function that returns the cType.
	 */
	string getHandleFunc()
	{
		if ( parentStruct && parentStruct.name == name )
			return "get"~ cast(char)pack.name[0].toUpper ~ pack.name[1..$] ~ name ~"Struct";
		else
			return "get"~ name ~"Struct";
	}

	bool isInterface()
	{
		if ( lookupInterface )
			return true;
		if ( lookupClass )
			return false;
		if ( type == GirStructType.Interface )
			return true;

		return false;
	}

	bool isNamespace()
	{
		return type == GirStructType.Record && !(lookupClass || lookupInterface) && !noNamespace;
	}

	void merge(GirStruct mergeStruct)
	{
		foreach ( func; mergeStruct.functions )
		{
			func.strct = this;
			functions[func.name] = func;
		}
	}

	GirStruct getAncestor()
	{
		if ( parent.empty )
			return this;

		if ( !parentStruct )
			parentStruct = pack.getStruct(parent);
		if ( !parentStruct )
			return this;

		return parentStruct.getAncestor();
	}

	private void resolveImports()
	{
		if ( parentStruct && parentStruct.name != name)
		{
			imports ~= parentStruct.pack.name ~"."~ parentStruct.name;
		}
		else if ( parentStruct )
		{
			string QParent = parentStruct.pack.name.capitalize() ~ parentStruct.name;
			imports ~= parentStruct.pack.name ~"."~ parentStruct.name ~" : "~ QParent ~" = "~ parentStruct.name;
			structWrap[parent] = QParent;
		}

		imports ~= pack.bindDir ~"."~ pack.name;
		imports ~= pack.bindDir ~"."~ pack.name ~"types";

		foreach( func; functions )
		{
			if ( func.noCode )
				continue;

			if ( func.throws )
			{
				imports ~= "glib.ErrorG";
				imports ~= "glib.GException";
			}

			void getReturnImport(GirType type)
			{
				if ( type.name in structWrap || type.name in aliases )
					return;

				GirStruct dType = pack.getStruct(type.name);

				if ( dType && (dType.type != GirStructType.Record || dType.lookupClass || dType.lookupInterface) )
				{
					if ( !dType.pack.name.among("cairo", "glib", "gthread") )
						imports ~= "gobject.ObjectG";

					if ( dType.type == GirStructType.Interface && func.name.startsWith("new") )
						return;

					if ( dType is this && dType.type != GirStructType.Interface )
						return;

					imports ~= dType.pack.name ~"."~ dType.name;

					if ( dType.type == GirStructType.Interface || dType.lookupInterface )
						imports ~= dType.pack.name ~"."~ dType.name ~"IF";
				}
				else if ( type.name == "utf8" || type.cType.among("guchar**") )
					imports ~= "glib.Str";
			}

			if ( func.returnType && func.returnType.cType !in structWrap )
			{
				getReturnImport(func.returnType);

				if ( func.returnType.isArray() )
					getReturnImport(func.returnType.elementType);
			}

			void getParamImport(GirType type)
			{
				if ( type.name in structWrap || type.name in aliases )
					return;

				GirStruct dType = pack.getStruct(type.name);

				if ( dType is this )
					return;
			
				if ( func.type == GirFunctionType.Signal && type.name.startsWith("Gdk.Event") )
					imports ~= "gdk.Event";

				if ( dType && (dType.type != GirStructType.Record || dType.lookupClass || dType.lookupInterface) )
				{
					if ( dType.type == GirStructType.Interface || dType.lookupInterface )
					{
						imports ~= dType.pack.name ~"."~ dType.name ~"IF";

						if ( func.type == GirFunctionType.Signal )
							imports ~= dType.pack.name ~"."~ dType.name;
					}
					else
					{
						imports ~= dType.pack.name ~"."~ dType.name;
					}
				}
				else if ( type.name == "utf8" || type.cType.among("guchar**") )
					imports ~= "glib.Str";
			}

			foreach ( param; func.params )
			{
				if ( param.type.cType in structWrap )
					continue;

				getParamImport(param.type);

				if ( param.type.elementType )
					getParamImport(param.type.elementType);

				if ( param.direction != GirParamDirection.Default )
					getReturnImport(param.type);
			}

			if ( func.type == GirFunctionType.Signal )
			{
				imports ~= "gobject.Signals";
			}

			if ( func.type == GirFunctionType.Constructor )
				imports ~= "glib.ConstructionException";
		}

		foreach ( interf; implements )
		{
			if ( parentStruct && parentStruct.implements.canFind(interf) )
				continue;

			GirStruct strct = pack.getStruct(interf);

			if ( strct )
			{
				imports ~= strct.pack.name ~"."~ strct.name ~"IF";
				imports ~= strct.pack.name ~"."~ strct.name ~"T";
			}
		}

		imports = uniq(sort(imports)).array;
	}

	private void writeImports(ref string buff, bool _public = false)
	{
		foreach ( imp; imports )
		{
			if ( _public || imp.endsWith("types") )
				buff ~= "public  import "~ imp ~";\n";
			else
				buff ~= "private import "~ imp ~";\n";
		}

		buff ~= "\n\n";
	}

	private void writeDocs(ref string buff)
	{
		if ( doc !is null && wrapper.includeComments )
		{
			buff ~= "/**\n";
			foreach ( line; doc.splitLines() )
				buff ~= " * "~ line.strip() ~"\n";

			if ( libVersion )
			{
				buff ~= " *\n * Since: "~ libVersion ~"\n";
			}

			buff ~= " */\n";
		}
		else if ( wrapper.includeComments )
		{
			buff ~= "/** */\n";
		}
	}

	private GirFunction getTypeFunction(string cIdentifier)
	{
		GirType returnType = new GirType(wrapper);
		returnType.name = "GObject.GType";
		returnType.cType = "GType";

		GirFunction func = new GirFunction(wrapper, this);
		func.type = GirFunctionType.Function;
		func.name = "get_type";
		func.cType = cIdentifier;
		func.returnType = returnType;

		if ( type == GirStructType.Interface )
			func.noCode = true;

		return func;
	}

	/**
	 * Get an overload of events that accept an generic Gdk Event
	 * instead of the spesific type listed in the gir files.
	 * 
	 * This for backwards compatibility with the documentation based wrapper.
	 */
	private string[] getGenericEventSignal(GirFunction func)
	{
		GirFunction signal = func.dup();
		string[] buff;
		
		for ( size_t i; i < signal.params.length; i++ )
		{
			if ( signal.params[i].type.name.startsWith("Gdk.Event") )
			{
				GirType eventType = new GirType(wrapper);
				eventType.name = "Gdk.Event";
				
				auto newParam = new GirParam(wrapper);
				newParam.name = signal.params[i].name;
				newParam.doc  = signal.params[i].doc;
				newParam.type = eventType;
				
				signal.params[i] = newParam;
				
				break;
			}
		}

		string[] declaration = signal.getAddListenerdeclaration();
		signal.name = signal.name ~ "-generic-event";
		
		buff ~= func.getDelegateDecleration() ~"[] on"~ signal.getSignalName() ~"Listeners;";
		buff ~= declaration;
		buff ~= signal.getAddListenerBody();
		buff ~= signal.getSignalCallback();
		
		return buff;
	}
}

final class GirField
{
	string name;
	string doc;
	GirType type;
	int bits = -1;

	GirFunction callback;
	GirUnion gtkUnion;
	GirStruct gtkStruct;

	GirWrapper wrapper;

	this(GirWrapper wrapper)
	{
		this.wrapper = wrapper;
	}

	void parse(T)(XMLReader!T reader)
	{
		name = reader.front.attributes["name"];

		if ( "bits" in reader.front.attributes )
			bits = to!int(reader.front.attributes["bits"]);

		//TODO: readable private?

		reader.popFront();

		while( !reader.empty && !reader.endTag("field") )
		{
			if ( reader.front.type == XMLNodeType.EndTag )
			{
				reader.popFront();
				continue;
			}

			switch(reader.front.value)
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
				case "array":
				case "type":
					type = new GirType(wrapper);
					type.parse(reader);
					break;
				case "callback":
					callback = new GirFunction(wrapper, null);
					callback.parse(reader);
					break;
				default:
					throw new XMLException(reader, "Unexpected tag: "~ reader.front.value ~" in GirField: "~ name);
			}
			reader.popFront();
		}
	}

	/**
	 * A special case for fields, we need to know about all of then
	 * to properly construct the bitfields.
	 */
	static string[] getFieldDeclarations(GirField[] fields, GirWrapper wrapper)
	{
		string[] buff;
		int bitcount;

		void endBitfield()
		{
			//AFAIK: C bitfields are padded to a multiple of sizeof uint.
			int padding = 32 - (bitcount % 32);

			if ( padding > 0 && padding < 32)
			{
				buff[buff.length-1] ~= ",";
				buff ~= "uint, \"\", "~ to!string(padding);
				buff ~= "));";
			}
			else
			{
				buff ~= "));";
			}

			bitcount = 0;
		}

		foreach ( field; fields )
		{
			if ( field.callback )
			{
				if ( bitcount > 0 )
					endBitfield();
				buff ~= field.callback.getFunctionPointerDecleration();
				continue;
			}

			if ( field.gtkUnion )
			{
				if ( bitcount > 0 )
					endBitfield();
				buff ~= field.gtkUnion.getUnionDeclaration();
				continue;
			}

			if ( field.gtkStruct )
			{
				if ( bitcount > 0 )
					endBitfield();
				buff ~= field.gtkStruct.getStructDeclaration();
				buff ~= stringToGtkD(field.gtkStruct.cType ~" "~ field.gtkStruct.name ~";", wrapper.aliasses);
				continue;
			}

			if ( field.bits > 0 )
			{
				if ( bitcount == 0 )
				{
					buff ~= "import std.bitmanip: bitfields;";
					buff ~= "mixin(bitfields!(";
				}
				else
				{
					buff[buff.length-1] ~= ",";
				}

				bitcount += field.bits;
				buff ~=stringToGtkD(field.type.cType ~", \""~ field.name ~"\", "~ to!string(field.bits), wrapper.aliasses);
				continue;
			}
			else if ( bitcount > 0)
			{
				endBitfield();
			}

			if ( field.doc !is null && wrapper.includeComments && field.bits < 0 )
			{
				buff ~= "/**";
				foreach ( line; field.doc.splitLines() )
					buff ~= " * "~ line.strip();
				buff ~= " */";
			}

			string dType;

			if ( field.type.size == -1 )
			{
				if ( field.type.cType.empty )
					dType = stringToGtkD(field.type.name, wrapper.aliasses);
				else
					dType = stringToGtkD(field.type.cType, wrapper.aliasses);
			}
			else if ( field.type.elementType.cType.empty )
			{
				//Special case for GObject.Value.
				dType = stringToGtkD(field.type.elementType.name, wrapper.aliasses);
				dType ~= "["~ to!string(field.type.size) ~"]";
			}
			else
			{
				dType = stringToGtkD(field.type.elementType.cType, wrapper.aliasses);
				dType ~= "["~ to!string(field.type.size) ~"]";
			}

			buff ~= dType ~" "~ tokenToGtkD(field.name, wrapper.aliasses) ~";";
		}

		if ( bitcount > 0)
		{
			endBitfield();
		}

		return buff;
	}
}

final class GirUnion
{
	string name;
	string doc;
	GirField[] fields;

	GirWrapper wrapper;

	this(GirWrapper wrapper)
	{
		this.wrapper = wrapper;
	}

	void parse(T)(XMLReader!T reader)
	{
		if ( "name" in reader.front.attributes )
			name = reader.front.attributes["name"];

		reader.popFront();

		while( !reader.empty && !reader.endTag("union") )
		{
			switch(reader.front.value)
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
				case "field":
					GirField field = new GirField(wrapper);
					field.parse(reader);
					fields ~= field;
					break;
				case "record":
					GirField field = new GirField(wrapper);
					GirStruct strct = new GirStruct(wrapper, null);
					strct.parse(reader);
					strct.cType = strct.cType.toUpper()[0..1] ~ strct.cType[1 .. $];
					field.gtkStruct = strct;
					fields ~= field;
					break;
				default:
					throw new XMLException(reader, "Unexpected tag: "~ reader.front.value ~" in GirUnion: "~ name);
			}
			reader.popFront();
		}
	}

	string[] getUnionDeclaration()
	{
		string[] buff;
		if ( doc !is null && wrapper.includeComments )
		{
			buff ~= "/**";
			foreach ( line; doc.splitLines() )
				buff ~= " * "~ line.strip();
			buff ~= " */";
		}

		if ( name )
			buff ~= "union "~ tokenToGtkD(name.toUpper()[0..1] ~ name[1 .. $], wrapper.aliasses);
		else
			buff ~= "union";

		buff ~= "{";
		buff ~= GirField.getFieldDeclarations(fields, wrapper);
		buff ~= "}";

		if ( name )
			buff ~= tokenToGtkD(name.toUpper()[0..1] ~ name[1 .. $], wrapper.aliasses) ~" "~ tokenToGtkD(name.toLower(), wrapper.aliasses) ~";";

		return buff;
	}
}
