/**
 * X11 protocol.
 * Work in progress.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.net.x11;

import std.algorithm.comparison : min;
import std.algorithm.searching;
import std.ascii : toLower;
import std.conv : to;
import std.exception;
import std.meta;
import std.process : environment;
import std.socket;
import std.traits : hasIndirections, ReturnType;
import std.typecons : Nullable;

public import deimos.X11.X;
public import deimos.X11.Xmd;
import deimos.X11.Xproto;
public import deimos.X11.Xprotostr;

import ae.net.asockets;
import ae.utils.array;
import ae.utils.exception : CaughtException;
import ae.utils.meta;
import ae.utils.promise;

debug(X11) import std.stdio : stderr;

/// These are always 32-bit in the protocol,
/// but are defined as possibly 64-bit in X.h.
/// Redefine these in terms of the protocol we implement here.
public
{
    alias CARD32    Window;
    alias CARD32    Drawable;
    alias CARD32    Font;
    alias CARD32    Pixmap;
    alias CARD32    Cursor;
    alias CARD32    Colormap;
    alias CARD32    GContext;
    alias CARD32    Atom;
    alias CARD32    VisualID;
    alias CARD32    Time;
    alias CARD8     KeyCode;
    alias CARD32    KeySym;
}

/// Used for CreateWindow and ChangeWindowAttributes.
struct WindowAttributes
{
	/// This will generate `Nullable` fields `backPixmap`, `backPixel`, ...
	mixin Optionals!(
		CWBackPixmap      , Pixmap               ,
		CWBackPixel       , CARD32               ,
		CWBorderPixmap    , Pixmap               ,
		CWBorderPixel     , CARD32               ,
		CWBitGravity      , typeof(ForgetGravity),
		CWWinGravity      , typeof(UnmapGravity) ,
		CWBackingStore    , typeof(NotUseful)    ,
		CWBackingPlanes   , CARD32               ,
		CWBackingPixel    , CARD32               ,
		CWOverrideRedirect, BOOL                 ,
		CWSaveUnder       , BOOL                 ,
		CWEventMask       , typeof(NoEventMask)  ,
		CWDontPropagate   , typeof(NoEventMask)  ,
		CWColormap        , Colormap             ,
		CWCursor          , Cursor               ,
	);
}

/// Used for ConfigureWindow.
struct WindowConfiguration
{
	/// This will generate `Nullable` fields `x`, `y`, ...
	mixin Optionals!(
		CWX           , INT16,
		CWY           , INT16,
		CWWidth       , CARD16,
		CWHeight      , CARD16,
		CWBorderWidth , CARD16,
		CWSibling     , Window,
		CWStackMode   , typeof(Above),
	);
}

/// Used for CreateGC, ChangeGC and CopyGC.
struct GCAttributes
{
	/// This will generate `Nullable` fields `c_function`, `planeMask`, ...
	mixin Optionals!(
		GCFunction          , typeof(GXclear)       ,
		GCPlaneMask         , CARD32                ,
		GCForeground        , CARD32                ,
		GCBackground        , CARD32                ,
		GCLineWidth         , CARD16                ,
		GCLineStyle         , typeof(LineSolid)     ,
		GCCapStyle          , typeof(CapNotLast)    ,
		GCJoinStyle         , typeof(JoinMiter)     ,
		GCFillStyle         , typeof(FillSolid)     ,
		GCFillRule          , typeof(EvenOddRule)   ,
		GCTile              , Pixmap                ,
		GCStipple           , Pixmap                ,
		GCTileStipXOrigin   , INT16                 ,
		GCTileStipYOrigin   , INT16                 ,
		GCFont              , Font                  ,
		GCSubwindowMode     , typeof(ClipByChildren),
		GCGraphicsExposures , BOOL                  ,
		GCClipXOrigin       , INT16                 ,
		GCClipYOrigin       , INT16                 ,
		GCClipMask          , Pixmap                ,
		GCDashOffset        , CARD16                ,
		GCDashList          , CARD8                 ,
		GCArcMode           , typeof(ArcChord)      ,
	);
}

/// `xReq` equivalent for requests with no arguments.
extern(C) struct xEmptyReq
{
    CARD8 reqType; /// As in `xReq`.
    CARD8 pad;     /// ditto
    CARD16 length; /// ditto
}

/// Base class for definitions shared by the core X11 protocol and
/// extensions.
private class X11SubProtocol
{
	struct RequestSpec(args...)
	if (args.length == 3)
	{
		enum reqType = args[0];
		enum reqName = __traits(identifier, args[0]);
		alias encoder = args[1];
		alias decoder = args[2];
		static assert(is(decoder == void) || !is(ReturnType!decoder == void));
		static if (is(decoder == void))
			alias ReturnType = void;
		else
			alias ReturnType = .ReturnType!decoder;
	}

	struct EventSpec(args...)
	if (args.length == 2)
	{
		enum name = __traits(identifier, args[0]);
		enum type = args[0];
		alias decoder = args[1];
		alias ReturnType = .ReturnType!decoder;
	}

	/// Instantiates to a function which accepts arguments and
	/// puts them into a struct, according to its fields.
	static template simpleEncoder(Req, string[] ignoreFields = [])
	{
		template isPertinentFieldIdx(size_t index)
		{
			enum name = __traits(identifier, Req.tupleof[index]);
			enum bool isPertinentFieldIdx =
				name != "reqType" &&
				name != "length" &&
				(name.length < 3 || name[0..min($, 3)] != "pad") &&
				!ignoreFields.contains(name);
		}
		alias FieldIdxType(size_t index) = typeof(Req.tupleof[index]);
		enum pertinentFieldIndices = Filter!(isPertinentFieldIdx, RangeTuple!(Req.tupleof.length));

		Data simpleEncoder(
			staticMap!(FieldIdxType, pertinentFieldIndices) args,
		) {
			Req req;

			foreach (i; RangeTuple!(args.length))
			{
				enum structIndex = pertinentFieldIndices[i];
				req.tupleof[structIndex] = args[i];
			}

			return Data((&req)[0 .. 1]);
		}
	}

	template simpleDecoder(Res)
	{
		template isPertinentFieldIdx(size_t index)
		{
			enum name = __traits(identifier, Res.tupleof[index]);
			enum bool isPertinentFieldIdx =
				name != "type" &&
				name != "sequenceNumber" &&
				name != "length" &&
				(name.length < 3 || name[0..min($, 3)] != "pad");
		}
		static struct DecodedResult
		{
			mixin((){
				import ae.utils.text.ascii : toDec;

				string code;
				foreach (i; RangeTuple!(Res.tupleof.length))
					static if (isPertinentFieldIdx!i)
						code ~= `typeof(Res.tupleof)[` ~ toDec(i) ~ `] ` ~ __traits(identifier, Res.tupleof[i]) ~ ";";
				return code;
			}());
		}
		alias FieldIdxType(size_t index) = typeof(Res.tupleof[index]);
		enum pertinentFieldIndices = Filter!(isPertinentFieldIdx, RangeTuple!(Res.tupleof.length));

		DecodedResult simpleDecoder(
			Data data,
		) {
			enforce(Res.sizeof < sz_xGenericReply || data.length == Res.sizeof,
				"Unexpected reply size");
			auto res = cast(Res*)data.contents.ptr;

			DecodedResult result;
			foreach (i; RangeTuple!(pertinentFieldIndices.length))
			{
				result.tupleof[i] = res.tupleof[pertinentFieldIndices[i]];
				debug(X11) stderr.writeln("[X11] << ", __traits(identifier, result.tupleof[i]), ": ", result.tupleof[i]);
			}

			return result;
		}
	}

	static Data pad4(Data packet)
	{
		packet.length = (packet.length + 3) / 4 * 4;
		return packet;
	}

	/// Generates code based on `RequestSpecs` and `EventSpecs`.
	/// Mix this into your extension definition to generate callable
	/// methods and event handlers.
	/// This mixin is also used to generate the core protocol glue code.
	mixin template ProtocolGlue()
	{
		import std.traits : Parameters, ReturnType;
		import std.exception : enforce;
		import ae.sys.data : Data;
		debug(X11) import std.stdio : stderr;

		/// To avoid repetition, methods for sending packets and handlers for events are generated.
		/// This will generate senders such as sendCreateWindow,
		/// and event handlers such as handleExpose.

		enum generatedCode = (){
			import ae.utils.text.ascii : toDec;

			string code;

			foreach (i, Spec; RequestSpecs)
			{
				enum index = toDec(i);
				assert(Spec.reqName[0 .. 2] == "X_");
				enum haveReply = !is(Spec.decoder == void);
				code ~= "public ";
				if (haveReply)
					code ~= "Promise!(ReturnType!(RequestSpecs[" ~ index ~ "].decoder))";
				else
					code ~= "void";
				code ~= " send" ~ Spec.reqName[2 .. $] ~ "(Parameters!(RequestSpecs[" ~ index ~ "].encoder) params) { ";
				debug(X11) code ~= " struct Request { typeof(params) p; } stderr.writeln(`[X11] > " ~ Spec.reqName ~ ": `, Request(params));";
				if (haveReply)
					code ~= `auto p = new typeof(return);`;
				code ~= "sendRequest(RequestSpecs[" ~ index ~ "].reqType, RequestSpecs[" ~ index ~ "].encoder(params), ";
				if (haveReply)
					debug (X11)
						code ~= "(Data data) { auto decoded = RequestSpecs[" ~ index ~ "].decoder(data); struct DecodedReply { typeof(decoded) d; } stderr.writeln(`[X11] < " ~ Spec.reqName ~ ": `, DecodedReply(decoded)); p.fulfill(decoded); }";
					else
						code ~= "(Data data) { p.fulfill(RequestSpecs[" ~ index ~ "].decoder(data)); }";
				else
					code ~= "null";
				code ~= ");";
				if (haveReply)
					code ~= "return p;";
				code ~=" }\n";
			}

			foreach (i, Spec; EventSpecs)
			{
				enum index = toDec(i);
				code ~= "public void delegate(ReturnType!(EventSpecs[" ~ index ~ "].decoder)) handle" ~ Spec.name ~ ";\n";
				code ~= "private void _handle" ~ Spec.name ~ "(Data packet) {\n";
				code ~= "  enforce(handle" ~ Spec.name ~ ", `No event handler for event: " ~ Spec.name ~ "`);\n";
				debug (X11)
					code ~= "  auto decoded = EventSpecs[" ~ index ~ "].decoder(packet); struct DecodedEvent { typeof(decoded) d; } stderr.writeln(`[X11] < " ~ Spec.name ~ ": `, DecodedEvent(decoded)); return handle" ~ Spec.name ~ "(decoded);";
				else
					code ~= "  return handle" ~ Spec.name ~ "(EventSpecs[" ~ index ~ "].decoder(packet));\n";
				code ~= "}\n";
			}

			code ~= "final private void registerEvents() {\n";
			foreach (i, Spec; EventSpecs)
				code ~= "  client.eventHandlers[firstEvent + " ~ toDec(Spec.type) ~ "] = &_handle" ~ Spec.name ~ ";\n";
			code ~= "}";

			return code;
		}();
		// pragma(msg, generatedCode);
		mixin(generatedCode);

		/// Helper version of `simpleEncoder` which skips the extension sub-opcode field
		// Note: this should be in the `static if` block below, but that causes a recursive template instantiation
		alias simpleExtEncoder(Req) = simpleEncoder!(Req, [reqTypeFieldName]);

		// Extension helpers
		static if (is(typeof(this) : X11Extension))
		{
			import std.traits : ReturnType;
			import deimos.X11.Xproto : xQueryExtensionReply;

			/// Forwarding constructor
			this(X11Client client, ReturnType!(simpleDecoder!xQueryExtensionReply) result)
			{
				super(client, result);
				registerEvents();
			}

			/// Plumbing from encoder to `X11Client.sendRequest`
			private void sendRequest(BYTE reqType, Data requestData, void delegate(Data) handler)
			{
				assert(requestData.length >= BaseReq.sizeof);
				assert(requestData.length % 4 == 0);
				auto pReq = cast(BaseReq*)requestData.contents.ptr;
				mixin(`pReq.` ~ reqTypeFieldName ~ ` = reqType;`);

				return client.sendRequest(majorOpcode, requestData, handler);
			}
		}

		/// Returns the `RequestSpec` for the request with the indicated opcode.
		public template RequestSpecOf(CARD8 reqType)
		{
			static foreach (Spec; RequestSpecs)
				static if (Spec.reqType == reqType)
					alias RequestSpecOf = Spec;
		}

		/// Returns the `EventSpec` for the event with the indicated opcode.
		public template EventSpecOf(CARD8 type)
		{
			static foreach (Spec; EventSpecs)
				static if (Spec.type == type)
					alias EventSpecOf = Spec;
		}
	}
}

/// Implements the X11 protocol as a client.
/// Allows connecting to a local or remote X11 server.
///
/// Note: Because of heavy use of code generation,
/// this class's API may be a little opaque.
/// You may instead find the example in demo/x11/demo.d
/// more illuminating.
final class X11Client : X11SubProtocol
{
	/// Connect to the default X server
	/// (according to `$DISPLAY`).
	this()
	{
		this(environment["DISPLAY"]);
	}

	/// Connect to the server described by the specified display
	/// string.
	this(string display)
	{
		this(parseDisplayString(display));
		configureAuthentication(display);
	}

	/// Parse a display string into connectable address specs.
	static AddressInfo[] parseDisplayString(string display)
	{
		auto hostParts = display.findSplit(":");
		enforce(hostParts, "Invalid display string: " ~ display);
		enforce(!hostParts[2].startsWith(":"), "DECnet is unsupported");

		enforce(hostParts[2].length, "No display number"); // Not to be confused with the screen number
		auto displayNumber = hostParts[2].findSplit(".")[0];

		string hostname = hostParts[0];
		AddressInfo[] result;

		version (Posix) // Try UNIX sockets first
		if (!hostname.length)
			foreach (useAbstract; [true, false]) // Try abstract UNIX sockets first
			{
				version (linux) {} else continue;
				auto path = (useAbstract ? "\0" : "") ~ "/tmp/.X11-unix/X" ~ displayNumber;
				auto addr = new UnixAddress(path);
				result ~= AddressInfo(AddressFamily.UNIX, SocketType.STREAM, cast(ProtocolType)0, addr, path);
			}

		if (!hostname.length)
			hostname = "localhost";

		result ~= getAddressInfo(hostname, (X_TCP_PORT + displayNumber.to!ushort).to!string);
		return result;
	}

	/// Connect to the given address specs.
	this(AddressInfo[] ai)
	{
		replyHandlers.length = 0x1_0000; // Allocate dynamically, to avoid bloating this.init
		registerEvents();

		conn = new SocketConnection;
		conn.handleConnect = &onConnect;
		conn.handleReadData = &onReadData;
		conn.connect(ai);
	}

	SocketConnection conn; /// Underlying connection.

	void delegate() handleConnect; /// Handler for when a connection is successfully established.
	@property void handleDisconnect(void delegate(string, DisconnectType) dg) { conn.handleDisconnect = dg; } /// Setter for a disconnect handler.

	void delegate(scope ref const xError error) handleError; /// Error handler

	void delegate(Data event) handleGenericEvent; /// GenericEvent handler

	/// Authentication information used during connection.
	string authorizationProtocolName;
	ubyte[] authorizationProtocolData; /// ditto

	private import std.stdio : File;

	/// Automatically attempt to configure authentication by reading ~/.Xauthority.
	void configureAuthentication(string display)
	{
		import std.path : expandTilde, buildPath;
		import std.socket : Socket;
		import ae.sys.paths : getHomeDir;

		auto hostParts = display.findSplit(":");
		auto host = hostParts[0];
		if (!host.length)
			return;
		if (host == "localhost")
			host = Socket.hostName;

		auto number = hostParts[2];
		number = number.findSplit(".")[0];

		foreach (ref record; XAuthorityReader(File(getHomeDir.buildPath(".Xauthority"), "rb")))
			if (record.address == host && record.number == number)
			{
				authorizationProtocolName = record.name;
				authorizationProtocolData = record.data;
				return;
			}
	}

	/// Xauthority parsing.
	struct AuthRecord
	{
		ushort family;
		string address;
		string number;
		string name;
		ubyte[] data;
	}

	struct XAuthorityReader
	{
		File f;

		this(File f) { this.f = f; popFront(); }

		AuthRecord front;
		bool empty;

		class EndOfFile : Throwable { this() { super(null); } }

		void popFront()
		{
			bool atStart = true;

			ushort readShort()
			{
				import ae.utils.bitmanip : BigEndian;
				import ae.sys.file : readExactly;

				BigEndian!ushort[1] result;
				if (!f.readExactly(result.bytes[]))
					throw atStart ? new EndOfFile : new Exception("Unexpected end of file");
				atStart = false;
				return result[0];
			}

			ubyte[] readBytes()
			{
				auto length = readShort();
				auto result = new ubyte[length];
				auto bytesRead = f.rawRead(result);
				enforce(bytesRead.length == length, "Unexpected end of file");
				return result;
			}

			try
			{
				front.family = readShort();
				front.address = readBytes().fromBytes!string;
				front.number = readBytes().fromBytes!string;
				front.name = readBytes().fromBytes!string;
				front.data = readBytes();
			}
			catch (EndOfFile)
				empty = true;
		}
	} // ditto

	/// Connection information received from the server.
	xConnSetupPrefix connSetupPrefix;
	xConnSetup connSetup; /// ditto
	string vendor; /// ditto
	immutable(xPixmapFormat)[] pixmapFormats; /// ditto
	struct Root
	{
		xWindowRoot root; /// Root window information.
		struct Depth
		{
			xDepth depth; /// Color depth information.
			immutable(xVisualType)[] visualTypes; /// ditto
		} /// Supported depths.
		Depth[] depths; /// ditto
	} /// ditto
	Root[] roots; /// ditto

	/// Generate a new resource ID, which can be used
	/// to identify resources created by this connection.
	CARD32 newRID()
	{
		auto counter = ridCounter++;
		CARD32 rid = connSetup.ridBase;
		foreach (ridBit; 0 .. typeof(rid).sizeof * 8)
		{
			auto ridMask = CARD32(1) << ridBit;
			if (connSetup.ridMask & ridMask) // May we use this bit?
			{
				auto bit = counter & 1;
				counter >>= 1;
				rid |= bit << ridBit;
			}
		}
		enforce(counter == 0, "RID counter overflow - too many RIDs");
		return rid;
	}

	// For internal use. Used by extension implementations to register
	// low level event handlers, via the `ProtocolGlue` mixin.
	// Clients should use the handleXXX functions.
	/*private*/ void delegate(Data packet)[0x80] eventHandlers;

	/// Request an extension.
	/// The promise is fulfilled with an instance of the extension
	/// bound to the current connection, or null if the extension is
	/// not available.
	Promise!Ext requestExtension(Ext : X11Extension)()
	{
		return sendQueryExtension(Ext.name)
			.dmd21804workaround
			.then((result) {
				if (result.present)
					return new Ext(this, result);
				else
					return null;
			});
	}

private:
	alias RequestSpecs = AliasSeq!(
		RequestSpec!(
			X_CreateWindow,
			function Data (
				// Request struct members
				CARD8 depth, 
				Window wid,
				Window parent,
				INT16 x,
				INT16 y,
				CARD16 width,
				CARD16 height,
				CARD16 borderWidth,
				CARD16 c_class,
				VisualID visual,

				// Optional parameters whose presence
				// is indicated by a bit mask
				in ref WindowAttributes windowAttributes,
			) {
				CARD32 mask;
				auto values = windowAttributes._serialize(mask);
				mixin(populateRequestFromLocals!xCreateWindowReq);
				return Data(req.bytes) ~ Data(values.bytes);
			},
			void,
		),

		RequestSpec!(
			X_ChangeWindowAttributes,
			function Data (
				// Request struct members
				Window window,

				// Optional parameters whose presence
				// is indicated by a bit mask
				in ref WindowAttributes windowAttributes,
			) {
				CARD32 valueMask;
				auto values = windowAttributes._serialize(valueMask);
				mixin(populateRequestFromLocals!xChangeWindowAttributesReq);
				return Data(req.bytes) ~ Data(values.bytes);
			},
			void,
		),

		RequestSpec!(
			X_GetWindowAttributes,
			simpleEncoder!xResourceReq,
			simpleDecoder!xGetWindowAttributesReply,
		),

		RequestSpec!(
			X_DestroyWindow,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_DestroySubwindows,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_ChangeSaveSet,
			simpleEncoder!xChangeSaveSetReq,
			void,
		),

		RequestSpec!(
			X_ReparentWindow,
			simpleEncoder!xReparentWindowReq,
			void,
		),

		RequestSpec!(
			X_MapWindow,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_MapSubwindows,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_UnmapWindow,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_UnmapSubwindows,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_ConfigureWindow,
			function Data (
				// Request struct members
				Window window,

				// Optional parameters whose presence
				// is indicated by a bit mask
				in ref WindowConfiguration windowConfiguration,
			) {
				CARD16 mask;
				auto values = windowConfiguration._serialize(mask);
				mixin(populateRequestFromLocals!xConfigureWindowReq);
				return Data(req.bytes) ~ Data(values.bytes);
			},
			void,
		),

		RequestSpec!(
			X_CirculateWindow,
			simpleEncoder!xCirculateWindowReq,
			void,
		),

		RequestSpec!(
			X_GetGeometry,
			simpleEncoder!xResourceReq,
			simpleDecoder!xGetGeometryReply,
		),

		RequestSpec!(
			X_QueryTree,
			simpleEncoder!xResourceReq,
			(Data data)
			{
				auto reader = DataReader(data);
				auto header = *reader.read!xQueryTreeReply().enforce("Unexpected reply size");
				auto children = reader.read!Window(header.nChildren).enforce("Unexpected reply size");
				enforce(reader.data.length == 0, "Unexpected reply size");
				struct Result
				{
					Window root;
					Window parent;
					Window[] children;
				}
				return Result(
					header.root,
					header.parent,
					children.toHeap(),
				);
			}
		),

		RequestSpec!(
			X_InternAtom,
			function Data (
				// Request struct members
				bool onlyIfExists,

				// Extra data
				const(char)[] name,

			) {
				auto nbytes = name.length.to!CARD16;
				mixin(populateRequestFromLocals!xInternAtomReq);
				return pad4(Data(req.bytes) ~ Data(name.bytes));
			},
			simpleDecoder!xInternAtomReply,
		),

		RequestSpec!(
			X_GetAtomName,
			simpleEncoder!xResourceReq,
			(Data data)
			{
				auto reader = DataReader(data);
				auto header = *reader.read!xGetAtomNameReply().enforce("Unexpected reply size");
				auto name = reader.read!char(header.nameLength).enforce("Unexpected reply size");
				enforce(reader.data.length < 4, "Unexpected reply size");

				return name.toHeap();
			}
		),

		RequestSpec!(
			X_ChangeProperty,
			function Data (
				// Request struct members
				CARD8 mode,
				Window window,
				Atom property,
				Atom type,
				CARD8 format,

				// Extra data
				const(ubyte)[] data,

			) {
				auto nUnits = (data.length * 8 / format).to!CARD32;
				mixin(populateRequestFromLocals!xChangePropertyReq);
				return pad4(Data(req.bytes) ~ Data(data.bytes));
			},
			void,
		),

		RequestSpec!(
			X_DeleteProperty,
			simpleEncoder!xDeletePropertyReq,
			void,
		),

		RequestSpec!(
			X_GetProperty,
			simpleEncoder!xGetPropertyReq,
			(Data data)
			{
				auto reader = DataReader(data);
				auto header = *reader.read!xGetPropertyReply().enforce("Unexpected reply size");
				auto dataLength = header.nItems * header.format / 8;
				auto value = reader.read!ubyte(dataLength).enforce("Unexpected reply size");
				enforce(reader.data.length < 4, "Unexpected reply size");

				struct Result
				{
					CARD8 format;
					Atom propertyType;
					CARD32 bytesAfter;
					const(ubyte)[] value;
				}
				return Result(
					header.format,
					header.propertyType,
					header.bytesAfter,
					value.toHeap(),
				);
			}
		),

		RequestSpec!(
			X_ListProperties,
			simpleEncoder!xResourceReq,
			(Data data)
			{
				auto reader = DataReader(data);
				auto header = *reader.read!xListPropertiesReply().enforce("Unexpected reply size");
				auto atoms = reader.read!Atom(header.nProperties).enforce("Unexpected reply size");
				enforce(reader.data.length < 4, "Unexpected reply size");

				return atoms.toHeap();
			}
		),

		RequestSpec!(
			X_SetSelectionOwner,
			simpleEncoder!xSetSelectionOwnerReq,
			void,
		),

		RequestSpec!(
			X_GetSelectionOwner,
			simpleEncoder!xResourceReq,
			simpleDecoder!xGetSelectionOwnerReply,
		),

		RequestSpec!(
			X_ConvertSelection,
			simpleEncoder!xConvertSelectionReq,
			void,
		),

		RequestSpec!(
			X_SendEvent,
			function Data (
				bool propagate,
				Window destination,
				CARD32 eventMask,
				xEvent event,
			) {
				auto eventdata = cast(byte[event.sizeof])event.bytes[0 .. event.sizeof];
				mixin(populateRequestFromLocals!xSendEventReq);
				return Data(req.bytes);
			},
			void,
		),

		RequestSpec!(
			X_GrabPointer,
			simpleEncoder!xGrabPointerReq,
			simpleDecoder!xGrabPointerReply,
		),

		RequestSpec!(
			X_UngrabPointer,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_GrabButton,
			simpleEncoder!xGrabButtonReq,
			void,
		),

		RequestSpec!(
			X_UngrabButton,
			simpleEncoder!xUngrabButtonReq,
			void,
		),

		RequestSpec!(
			X_ChangeActivePointerGrab,
			simpleEncoder!xChangeActivePointerGrabReq,
			void,
		),

		RequestSpec!(
			X_GrabKeyboard,
			simpleEncoder!xGrabKeyboardReq,
			simpleDecoder!xGrabKeyboardReply,
		),

		RequestSpec!(
			X_UngrabKeyboard,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_GrabKey,
			simpleEncoder!xGrabKeyReq,
			void,
		),

		RequestSpec!(
			X_UngrabKey,
			simpleEncoder!xUngrabKeyReq,
			void,
		),

		RequestSpec!(
			X_AllowEvents,
			simpleEncoder!xAllowEventsReq,
			void,
		),

		RequestSpec!(
			X_GrabServer,
			simpleEncoder!xEmptyReq,
			void,
		),

		RequestSpec!(
			X_UngrabServer,
			simpleEncoder!xEmptyReq,
			void,
		),

		RequestSpec!(
			X_QueryPointer,
			simpleEncoder!xResourceReq,
			simpleDecoder!xQueryPointerReply,
		),

		RequestSpec!(
			X_GetMotionEvents,
			simpleEncoder!xGetMotionEventsReq,
			(Data data)
			{
				auto reader = DataReader(data);
				auto header = *reader.read!xGetMotionEventsReply().enforce("Unexpected reply size");
				auto events = reader.read!xTimecoord(header.nEvents).enforce("Unexpected reply size");
				enforce(reader.data.length == 0, "Unexpected reply size");

				return events.arr.idup;
			}
		),

		RequestSpec!(
			X_TranslateCoords,
			simpleEncoder!xTranslateCoordsReq,
			simpleDecoder!xTranslateCoordsReply,
		),

		RequestSpec!(
			X_WarpPointer,
			simpleEncoder!xWarpPointerReq,
			void,
		),

		RequestSpec!(
			X_SetInputFocus,
			simpleEncoder!xSetInputFocusReq,
			void,
		),

		RequestSpec!(
			X_GetInputFocus,
			simpleEncoder!xEmptyReq,
			simpleDecoder!xGetInputFocusReply,
		),

		RequestSpec!(
			X_QueryKeymap,
			simpleEncoder!xEmptyReq,
			simpleDecoder!xQueryKeymapReply,
		),

		RequestSpec!(
			X_OpenFont,
			simpleEncoder!xOpenFontReq,
			void,
		),

		RequestSpec!(
			X_CloseFont,
			simpleEncoder!xResourceReq,
			void,
		),

		// RequestSpec!(
		// 	X_QueryFont,
		// 	simpleEncoder!xResourceReq,
		// 	TODO
		// ),

		// ...

		RequestSpec!(
			X_CreateGC,
			function Data (
				// Request struct members
				GContext gc,
				Drawable drawable,

				// Optional parameters whose presence
				// is indicated by a bit mask
				in ref GCAttributes gcAttributes,
			) {
				CARD32 mask;
				auto values = gcAttributes._serialize(mask);
				mixin(populateRequestFromLocals!xCreateGCReq);
				return Data(req.bytes) ~ Data(values.bytes);
			},
			void,
		),

		// ...

		RequestSpec!(
			X_ImageText8,
			function Data (
				// Request struct members
				Drawable drawable,
				GContext gc,
				INT16 x,
				INT16 y,

				// Extra data
				const(char)[] string,

			) {
				auto nChars = string.length.to!ubyte;
				mixin(populateRequestFromLocals!xImageText8Req);
				return pad4(Data(req.bytes) ~ Data(string.bytes));
			},
			void,
		),

		// ...

		RequestSpec!(
			X_PolyFillRectangle,
			function Data (
				// Request struct members
				Drawable drawable,
				GContext gc,

				// Extra data
				const(xRectangle)[] rectangles,

			) {
				mixin(populateRequestFromLocals!xPolyFillRectangleReq);
				return Data(req.bytes) ~ Data(rectangles.bytes);
			},
			void,
		),

		// ...

		RequestSpec!(
			X_QueryExtension,
			function Data (
				// Extra data
				const(char)[] name,

			) {
				auto nbytes = name.length.to!ubyte;
				mixin(populateRequestFromLocals!xQueryExtensionReq);
				return pad4(Data(req.bytes) ~ Data(name.bytes));
			},
			simpleDecoder!xQueryExtensionReply,
		),

		// ...
	);

	alias EventSpecs = AliasSeq!(
		EventSpec!(KeyPress        , simpleDecoder!(xEvent.KeyButtonPointer)),
		EventSpec!(KeyRelease      , simpleDecoder!(xEvent.KeyButtonPointer)),
		EventSpec!(ButtonPress     , simpleDecoder!(xEvent.KeyButtonPointer)),
		EventSpec!(ButtonRelease   , simpleDecoder!(xEvent.KeyButtonPointer)),
		EventSpec!(MotionNotify    , simpleDecoder!(xEvent.KeyButtonPointer)),
		EventSpec!(EnterNotify     , simpleDecoder!(xEvent.EnterLeave      )),
		EventSpec!(LeaveNotify     , simpleDecoder!(xEvent.EnterLeave      )),
		EventSpec!(FocusIn         , simpleDecoder!(xEvent.Focus           )),
		EventSpec!(FocusOut        , simpleDecoder!(xEvent.Focus           )),
		EventSpec!(KeymapNotify    , simpleDecoder!(xKeymapEvent           )),
		EventSpec!(Expose          , simpleDecoder!(xEvent.Expose          )),
		EventSpec!(GraphicsExpose  , simpleDecoder!(xEvent.GraphicsExposure)),
		EventSpec!(NoExpose        , simpleDecoder!(xEvent.NoExposure      )),
		EventSpec!(VisibilityNotify, simpleDecoder!(xEvent.Visibility      )),
		EventSpec!(CreateNotify    , simpleDecoder!(xEvent.CreateNotify    )),
		EventSpec!(DestroyNotify   , simpleDecoder!(xEvent.DestroyNotify   )),
		EventSpec!(UnmapNotify     , simpleDecoder!(xEvent.UnmapNotify     )),
		EventSpec!(MapNotify       , simpleDecoder!(xEvent.MapNotify       )),
		EventSpec!(MapRequest      , simpleDecoder!(xEvent.MapRequest      )),
		EventSpec!(ReparentNotify  , simpleDecoder!(xEvent.Reparent        )),
		EventSpec!(ConfigureNotify , simpleDecoder!(xEvent.ConfigureNotify )),
		EventSpec!(ConfigureRequest, simpleDecoder!(xEvent.ConfigureRequest)),
		EventSpec!(GravityNotify   , simpleDecoder!(xEvent.Gravity         )),
		EventSpec!(ResizeRequest   , simpleDecoder!(xEvent.ResizeRequest   )),
		EventSpec!(CirculateNotify , simpleDecoder!(xEvent.Circulate       )),
		EventSpec!(CirculateRequest, simpleDecoder!(xEvent.Circulate       )),
		EventSpec!(PropertyNotify  , simpleDecoder!(xEvent.Property        )),
		EventSpec!(SelectionClear  , simpleDecoder!(xEvent.SelectionClear  )),
		EventSpec!(SelectionRequest, simpleDecoder!(xEvent.SelectionRequest)),
		EventSpec!(SelectionNotify , simpleDecoder!(xEvent.SelectionNotify )),
		EventSpec!(ColormapNotify  , simpleDecoder!(xEvent.Colormap        )),
		EventSpec!(ClientMessage   ,
			function(
				Data data,
			) {
				auto reader = DataReader(data);
				auto packet = *reader.read!(xEvent.ClientMessage)().enforce("Unexpected reply size");
				struct Result
				{
					Atom type;
					ubyte[20] bytes;
				}
				return Result(
					packet.b.type,
					cast(ubyte[20])packet.b.bytes,
				);
			}
		),
		EventSpec!(MappingNotify   , simpleDecoder!(xEvent.MappingNotify   )),
	//	EventSpec!(GenericEvent    , simpleDecoder!(xGenericEvent          )),
	);

	@property X11Client client() { return this; }
	enum firstEvent = 0;

	mixin ProtocolGlue;

	void onConnect()
	{
		xConnClientPrefix prefix;
		version (BigEndian)
			prefix.byteOrder = 'B';
		version (LittleEndian)
			prefix.byteOrder = 'l';
		prefix.majorVersion = X_PROTOCOL;
		prefix.minorVersion = X_PROTOCOL_REVISION;
		prefix.nbytesAuthProto6 = authorizationProtocolName.length.to!CARD16;
		prefix.nbytesAuthString = authorizationProtocolData.length.to!CARD16;

		conn.send(Data(prefix.bytes));
		conn.send(pad4(Data(authorizationProtocolName)));
		conn.send(pad4(Data(authorizationProtocolData)));
	}

	Data buffer;

	bool connected;

	ushort sequenceNumber = 1;
	void delegate(Data)[] replyHandlers;

	uint ridCounter; // for newRID

	void onReadData(Data data)
	{
		buffer ~= data;

		try
			while (true)
			{
				if (!connected)
				{
					auto reader = DataReader(buffer);

					auto pConnSetupPrefix = reader.read!xConnSetupPrefix();
					if (!pConnSetupPrefix)
						return;

					auto additionalBytes = reader.read!uint((*pConnSetupPrefix).length);
					if (!additionalBytes)
						return;
					auto additionalReader = DataReader(additionalBytes.data);

					connSetupPrefix = *pConnSetupPrefix;
					switch ((*pConnSetupPrefix).success)
					{
						case 0: // Failed
						{
							auto reason = additionalReader.read!char((*pConnSetupPrefix).lengthReason)
								.enforce("Insufficient bytes for reason");
							conn.disconnect("X11 connection failed: " ~ cast(string)reason.arr, DisconnectType.error);
							break;
						}
						case 1: // Success
						{
							auto pConnSetup = additionalReader.read!xConnSetup()
								.enforce("Connection setup packet too short");
							connSetup = *pConnSetup;

							auto vendorBytes = additionalReader.read!uint(((*pConnSetup).nbytesVendor + 3) / 4)
								.enforce("Connection setup packet too short");
							this.vendor = DataReader(vendorBytes.data).read!char((*pConnSetup).nbytesVendor).arr.idup;

							// scope(failure) { import std.stdio, ae.utils.json; writeln(connSetupPrefix.toPrettyJson); writeln(connSetup.toPrettyJson); writeln(pixmapFormats.toPrettyJson); writeln(roots.toPrettyJson); }

							this.pixmapFormats =
								additionalReader.read!xPixmapFormat((*pConnSetup).numFormats)
								.enforce("Connection setup packet too short")
								.arr.idup;
							foreach (i; 0 .. (*pConnSetup).numRoots)
							{
								Root root;
								// scope(failure) { import std.stdio, ae.utils.json; writeln(root.toPrettyJson); }
								root.root = *additionalReader.read!xWindowRoot()
									.enforce("Connection setup packet too short");
								foreach (j; 0 .. root.root.nDepths)
								{
									Root.Depth depth;
									depth.depth = *additionalReader.read!xDepth()
										.enforce("Connection setup packet too short");
									depth.visualTypes = additionalReader.read!xVisualType(depth.depth.nVisuals)
										.enforce("Connection setup packet too short")
										.arr.idup;
									root.depths ~= depth;
								}
								this.roots ~= root;
							}

							enforce(!additionalReader.data.length,
								"Left-over bytes in connection setup packet");

							connected = true;
							if (handleConnect)
								handleConnect();

							break;
						}
						case 2: // Authenticate
						{
							auto reason = additionalReader.read!char((*pConnSetupPrefix).lengthReason)
								.enforce("Insufficient bytes for reason");
							conn.disconnect("X11 authentication required: " ~ cast(string)reason.arr, DisconnectType.error);
							break;
						}
						default:
							throw new Exception("Unknown connection success code");
					}

					buffer = reader.data;
				}

				if (connected)
				{
					auto reader = DataReader(buffer);

					auto pGenericReply = reader.peek!xGenericReply();
					if (!pGenericReply)
						return;

					Data packet;

					switch ((*pGenericReply).type)
					{
						case X_Error:
						default:
							packet = reader.read!xGenericReply().data;
							assert(packet);
							break;
						case X_Reply:
						case GenericEvent:
							packet = reader.read!uint(8 + (*pGenericReply).length).data;
							if (!packet)
								return;
							break;
					}

					switch ((*pGenericReply).type)
					{
						case X_Error:
							if (handleError)
								handleError(*DataReader(packet).read!xError);
							else
							{
								debug (X11) stderr.writeln(*DataReader(packet).read!xError);
								throw new Exception("Protocol error");
							}
							break;
						case X_Reply:
							onReply(packet);
							break;
						case GenericEvent:
							if (handleGenericEvent)
								handleGenericEvent(packet);
							break;
						default:
							onEvent(packet);
					}

					buffer = reader.data;
				}
			}
		catch (CaughtException e)
			conn.disconnect(e.msg, DisconnectType.error);
	}

	void onReply(Data packet)
	{
		auto pHeader = DataReader(packet).peek!xGenericReply;
		auto handler = replyHandlers[(*pHeader).sequenceNumber];
		enforce(handler !is null,
			"Unexpected packet");
		replyHandlers[(*pHeader).sequenceNumber] = null;
		handler(packet);
	}

	void onEvent(Data packet)
	{
		auto pEvent = DataReader(packet).peek!xEvent;
		auto eventType = (*pEvent).u.type & 0x7F;
		// bool artificial = !!((*pEvent).u.type >> 7);
		auto handler = eventHandlers[eventType];
		if (!handler)
			throw new Exception("Unrecognized event: " ~ eventType.to!string);
		return handler(packet);
	}

	/*private*/ public void sendRequest(BYTE reqType, Data requestData, void delegate(Data) handler)
	{
		assert(requestData.length >= sz_xReq);
		assert(requestData.length % 4 == 0);
		auto pReq = cast(xReq*)requestData.contents.ptr;
		pReq.reqType = reqType;
		pReq.length = (requestData.length / 4).to!ushort;

		enforce(replyHandlers[sequenceNumber] is null,
			"Sequence number overflow"); // We haven't yet received a reply from the previous cycle
		replyHandlers[sequenceNumber] = handler;
		conn.send(requestData);
		sequenceNumber++;
	}
}

// ************************************************************************

/// Base class for X11 extensions.
abstract class X11Extension : X11SubProtocol
{
	X11Client client;
	CARD8 majorOpcode, firstEvent, firstError;

	this(X11Client client, ReturnType!(simpleDecoder!xQueryExtensionReply) reply)
	{
		this.client = client;
		this.majorOpcode = reply.major_opcode;
		this.firstEvent = reply.first_event;
		this.firstError = reply.first_error;
	}
}

/// Example extension:
version (none)
class XEXAMPLE : X11Extension
{
	/// Mix this in to generate sendXXX and handleXXX declarations.
	mixin ProtocolGlue;

	/// The name by which to request the extension (as in X_QueryExtension).
	enum name = XEXAMPLE_NAME;
	/// The extension's base request type.
	alias BaseReq = xXExampleReq;
	/// The name of the field encoding the extension's opcode.
	enum reqTypeFieldName = q{xexampleReqType};

	/// Declare the extension's requests here.
	alias RequestSpecs = AliasSeq!(
		RequestSpec!(
			X_XExampleRequest,
			simpleExtEncoder!xXExampleRequestReq,
			simpleDecoder!xXExampleRequestReply,
		),
	);

	/// Declare the extension's events here.
	alias EventSpecs = AliasSeq!(
		EventSpec!(XExampleNotify, simpleDecoder!xXExampleNotifyEvent),
	);
}

// ************************************************************************

private:

mixin template Optionals(args...)
if (args.length % 2 == 0)
{
	alias _args = args; // DMD bug workaround

	private mixin template Field(size_t i)
	{
		alias Type = args[i * 2 + 1];
		enum maskName = __traits(identifier, args[i * 2]);
		enum fieldName = toLower(maskName[2]) ~ maskName[3 .. $];
		enum prefix = is(typeof(mixin("(){int " ~ fieldName ~ "; }()"))) ? "" : "c_";
		mixin(`Nullable!Type ` ~ prefix ~ fieldName ~ ';');
	}

	static foreach (i; 0 .. args.length / 2)
		mixin Field!i;

	CARD32[] _serialize(Mask)(ref Mask mask) const
	{
		CARD32[] result;
		static foreach (i; 0 .. _args.length / 2)
			if (!this.tupleof[i].isNull)
			{
				enum fieldMask = _args[i * 2];
				assert(mask < fieldMask);
				result ~= this.tupleof[i].get();
				mask |= fieldMask;
			}
		return result;
	}
}

/// Generate code to populate all of a request struct's fields from arguments / locals.
string populateRequestFromLocals(T)()
{
	string code = T.stringof ~ " req;\n";
	foreach (i; RangeTuple!(T.tupleof.length))
	{
		enum name = __traits(identifier, T.tupleof[i]);
		enum isPertinentField =
			name != "reqType" &&
			name != "length" &&
			(name.length < 3 || name[0..min($, 3)] != "pad");
		if (isPertinentField)
		{
			code ~= "req." ~ name ~ " = " ~ name ~ ";\n";
			debug(X11) code ~= `stderr.writeln("[X11] >> ` ~ name ~ `: ", ` ~ name ~ `);`;
		}
	}
	return code;
}

// ************************************************************************

/// Typed wrapper for Data.
/// Because Data is reference counted, this type allows encapsulating
/// a safe but typed reference to a Data slice.
struct DataObject(T)
if (!hasIndirections!T)
{
	Data data;

	T opCast(T : bool)() const
	{
		return !!data;
	}

	@property T* ptr()
	{
		assert(data && data.length == T.sizeof);
		return cast(T*)data.contents.ptr;
	}

	ref T opUnary(string op : "*")()
	{
		return *ptr;
	}
}

/// Ditto, but a dynamic array of values.
struct DataArray(T)
if (!hasIndirections!T)
{
	Data data;
	@property T[] arr()
	{
		assert(data && data.length % T.sizeof == 0);
		return cast(T[])data.contents;
	}

	T opCast(T : bool)() const
	{
		return !!data;
	}

	@property T[] toHeap()
	{
		assert(data && data.length % T.sizeof == 0);
		return cast(T[])data.toHeap;
	}
}

/// Consumes bytes from a Data instance and returns them as typed objects on request.
/// Consumption must be committed explicitly once all desired bytes are read.
struct DataReader
{
	Data data;

	DataObject!T peek(T)()
	if (!hasIndirections!T)
	{
		if (data.length < T.sizeof)
			return DataObject!T.init;
		return DataObject!T(data[0 .. T.sizeof]);
	}

	DataArray!T peek(T)(size_t length)
	if (!hasIndirections!T)
	{
		auto size = T.sizeof * length;
		if (data.length < size)
			return DataArray!T.init;
		return DataArray!T(data[0 .. size]);
	}

	DataObject!T read(T)()
	if (!hasIndirections!T)
	{
		if (auto p = peek!T())
		{
			data = data[T.sizeof .. $];
			return p;
		}
		return DataObject!T.init;
	}

	DataArray!T read(T)(size_t length)
	if (!hasIndirections!T)
	{
		if (auto p = peek!T(length))
		{
			data = data[T.sizeof * length .. $];
			return p;
		}
		return DataArray!T.init;
	}
}
