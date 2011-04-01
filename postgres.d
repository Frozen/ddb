module postgres;

import std.socket, std.socketstream;
import std.exception;
import std.conv;
import std.traits;
import std.typecons;
import std.string;
import std.md5;
import std.intrinsic;
import std.variant;
import std.algorithm;
public import db;

private:

short hton(short i)
{
    version (BigEndian)
    {
        return i;
    }
    else
    {
        ubyte* b = cast(ubyte*)&i;
        ubyte l = *b;
        *b = *(b + 1);
        *(b + 1) = l;
        
        return i;
    }
}

int hton(const int i)
{
    version (BigEndian)
    {
        return i;
    }
    else
    {
        return cast(int)bswap(cast(uint)i);
    }
}

class PGStream : SocketStream
{
    this(Socket socket)
    {
        super(socket);
    }
    
    override void write(ubyte x)
    {
        super.write(x);
    }
    
    override void write(short x)
    {
        super.write(hton(x));
    }
    
    override void write(int x)
    {
        super.write(hton(x));
    }
    
    override void write(long x)
    {
        uint u;
    
        u = hton(cast(uint)(x >> 32));
        super.write(u);
    
        u = hton(cast(uint)x);
        super.write(u);
    }
    
    override void write(float x)
    {
        union U
        {
            float f;
            int i;
        }
        
        U u;
        u.f = x;
        
        super.write(hton(u.i));
    }
    
    override void write(double x)
    {
        union U
        {
            double d;
            long l;			
        }
        
        U u;
        u.d = x;
        
        write(u.l);
    }
    
    void writeCString(string x)
    {
        super.writeString(x);
        super.write('\0');
    }
}

string MD5toHex(in void[][] data...)
{
    return tolower(getDigestString(data));
}

struct Message
{
    PGConnection conn;
    char type;
    ubyte[] data;
    
    private size_t position = 0;
    private alias hton ntoh;
    
    T read(T)()
    {
        T value;
        read(value);
        return value;
    }
    
    void read()(out char x)
    {
        x = data[position++];
    }
    
    void read()(out short x)
    {
        x = ntoh(*(cast(short*)(data.ptr + position)));
        position += 2;
    }

    void read()(out int x)
    {
        x = ntoh(*(cast(int*)(data.ptr + position)));
        position += 4;
    }
    
    void read()(out long x)
    {
        uint h = ntoh(*(cast(uint*)(data.ptr + position)));
        uint l = ntoh(*(cast(uint*)(data.ptr + position + 4)));
        x = (cast(long)h << 32) | l;
        position += 8;
    }
    
    void read()(out float x)
    {
        union U
        {
            float f;
            int i;
        }
        
        U u;
        read(u.i);
        x = u.f;
    }
    
    void read()(out double x)
    {
        union U
        {
            double d;
            long l;
        }
        
        U u;
        read(u.l);
        x = u.d;
    }
    
    string readCString()
    {
        string x;
        readCString(x);
        return x;
    }
    
    void readCString(out string x)
    {
        ubyte* p = data.ptr + position;
        
        while (*p > 0)
            p++;
        
        x = cast(string)data[position .. cast(size_t)(p - data.ptr)];
        position = cast(size_t)(p - data.ptr + 1);
    }
    
    string readString(int len)
    {
        string x;
        readString(x, len);
        return x;
    }
    
    void readString(out string x, int len)
    {
        x = cast(string)data[position .. position + len];
        position += len;
    }
    
    void read()(out uint x)
    {
        x = ntoh(*(cast(uint*)(data.ptr + position)));
        position += 4;
    }
    
    void read()(out bool x)
    {
        x = cast(bool)data[position++];
    }
    
    T readComposite(T)()
    {
        alias DBRow!T Record;

        static if (Record.hasStaticLength)
        {
            alias Record.fieldTypes fieldTypes;
            
            static string genFieldAssigns() // CTFE
            {
                string s = "";
                
                foreach (i, type; fieldTypes)
                {
                    s ~= "read(fieldOid);";
                    s ~= "read(fieldLen);";
                    s ~= "if (fieldLen == -1)";
                    s ~= text("record.setNull!(", i, ")();");
                    s ~= "else\n";
                    s ~= text("record.set!(fieldTypes[", i, "], ", i, ")(",
                              "readBaseType!(fieldTypes[", i, "])(fieldOid, fieldLen)",
                              ");");
                }
                
                return s;
            }
        }

        Record record;
        
        int fieldCount, fieldLen;
        uint fieldOid;
        
        read(fieldCount);
        
        static if (Record.hasStaticLength)
            mixin(genFieldAssigns);
        else
        {
            record.setLength(fieldCount);
            
            foreach (i; 0 .. fieldCount)
            {
                read(fieldOid);
                read(fieldLen);
                
                if (fieldLen == -1)
                    record.setNull(i);
                else
                    record[i] = readBaseType!(Record.ElemType)(fieldOid, fieldLen);
            }
        }
        
        return record.base;
    }
    
    private AT readDimension(AT)(int[] lengths, uint elementOid, int dim)
    {
        alias typeof(AT[0]) ElemType;
        
        int length = lengths[dim];
        
        AT array;
        static if (isDynamicArray!AT)
            array.length = length;
        
        int fieldLen;
        
        foreach(i; 0 .. length)
        {
            static if (isArray!ElemType && !isSomeString!ElemType)
                array[i] = readDimension!ElemType(lengths, elementOid, dim + 1);
            else
            {
                static if (isNullable!ElemType)
                    alias nullableTarget!ElemType E;
                else
                    alias ElemType E;
                
                read(fieldLen);
                if (fieldLen == -1)
                {
                    static if (isNullable!ElemType || isSomeString!ElemType)
                        array[i] = null;
                    else
                        throw new Exception("Can't set NULL value to non nullable type");
                }
                else
                    array[i] = readBaseType!E(elementOid, fieldLen);
            }
        }
        
        return array;
    }
    
    T readArray(T)()
        if (isArray!T)
    {
        alias multiArrayElemType!T U;
        
        // todo: more validation, better lowerBounds support
        int dims, hasNulls;
        uint elementOid;
        int[] lengths, lowerBounds;
        
        read(dims);
        read(hasNulls); // 0 or 1
        read(elementOid);
        
        if (dims == 0)
            return T.init;
        
        enforce(arrayDimensions!T == dims, "Dimensions of arrays do not match");
        static if (!isNullable!U && !isSomeString!U)
            enforce(!hasNulls, "PostgreSQL returned NULLs but array elements are not Nullable");
        
        lengths.length = lowerBounds.length = dims;
        
        int elementCount = 1;
        
        foreach(i; 0 .. dims)
        {
            int len;
            
            read(len);
            read(lowerBounds[i]);
            lengths[i] = len;
            
            elementCount *= len;
        }
        
        T array = readDimension!T(lengths, elementOid, 0);
        
        return array;
    }
    
    T readEnum(T)(int len)
    {
        string genCases() // CTFE
        {
            string s;
            
            foreach (name; __traits(allMembers, T))
            {
                s ~= text(`case "`, name, `": return T.`, name, `;`);
            }
            
            return s;
        }
        
        string enumMember = readString(len);
        
        switch (enumMember)
        {
            mixin(genCases);
            default: throw new ConvException("Can't set enum value '" ~ enumMember ~ "' to enum type " ~ T.stringof);
        }
    }
    
    T readBaseType(T)(uint oid, int len = 0)
    {
        void convError(T)()
        {
            string* type = oid in baseTypes;
            throw new ConvException("Can't convert PostgreSQL's type " ~ (type ? *type : to!string(oid)) ~ " to " ~ T.stringof);
        }

        switch (oid)
        {
            case 16: // bool
            {
                static if (isConvertible!(T, bool))
                    return _to!T(read!bool);
                else
                    convError!T;
            }		
            case 26, 24, 2202, 2203, 2204, 2205, 2206, 3734, 3769: // oid and reg*** aliases
            {
                static if (isConvertible!(T, uint))
                    return _to!T(read!uint);
                else
                    convError!T;
            }
            case 21: // int2
            {
                static if (isConvertible!(T, short))
                    return _to!T(read!short);
                else
                    convError!T;
            }
            case 23: // int4
            {
                static if (isConvertible!(T, int))
                    return _to!T(read!int);
                else
                    convError!T;
            }
            case 20: // int8
            {
                static if (isConvertible!(T, long))
                    return _to!T(read!long);
                else
                    convError!T;
            }
            case 700: // float4
            {
                static if (isConvertible!(T, float))
                    return _to!T(read!float);
                else
                    convError!T;
            }
            case 701: // float8
            {
                static if (isConvertible!(T, double))
                    return _to!T(read!double);
                else
                    convError!T;
            }
            case 1042, 1043, 25, 19, 705: // bpchar, varchar, text, name, unknown
            {
                static if (isConvertible!(T, string))
                    return _to!T(readString(len));
                else
                    convError!T;
            }
            case 18: // "char"
            {
                static if (isConvertible!(T, char))
                    return _to!T(read!char);
                else
                    convError!T;
            }
            case 2249: // record and other composite types
            {
                static if (isVariantN!T && T.allowed!(Variant[]))
                    return T(readComposite!(Variant[]));
                else
                    return readComposite!T;
            }
            case 2287: // _record and other arrays
            {
                static if (isArray!T && !isSomeString!T)
                    return readArray!T;
                else static if (isVariantN!T && T.allowed!(Variant[]))
                    return T(readArray!(Variant[]));
                else
                    convError!T;
            }
            default:
            {
                if (oid in conn.arrayTypes)
                    goto case 2287;
                else if (oid in conn.compositeTypes)
                    goto case 2249;
                else if (oid in conn.enumTypes)
                {
                    static if (is(T == enum))
                        return readEnum!T(len);
                    else static if (isConvertible!(T, string))
                        return _to!T(readString(len));
                    else
                        convError!T;
                }
            }
        }
        
        convError!T;
        assert(0);
    }
}

// workaround, because std.conv doesn't support VariantN
template _to(T)
{
    static if (isVariantN!T)
        T _to(S)(S value) { T t = value; return t; }
    else
        T _to(A...)(A args) { return toImpl!T(args); }
}

template isConvertible(T, S)
{
    static if (__traits(compiles, { S s; _to!T(s); }) || (isVariantN!T && T.allowed!S))
        enum isConvertible = true;
    else
        enum isConvertible = false;
}

template arrayDimensions(T)
{
    static if (isArray!T && !isSomeString!T)
        enum arrayDimensions = arrayDimensions!(typeof(T[0])) + 1;
    else
        enum arrayDimensions = 0;
}

template multiArrayElemType(T)
{
    static if (isArray!T && !isSomeString!T)
        alias multiArrayElemType!(typeof(T[0])) multiArrayElemType;
    else
        alias T multiArrayElemType;
}

static assert(arrayDimensions!(int) == 0);
static assert(arrayDimensions!(int[]) == 1);
static assert(arrayDimensions!(int[][]) == 2);
static assert(arrayDimensions!(int[][][]) == 3);

enum TransactionStatus : char { OutsideTransaction = 'I', InsideTransaction = 'T', InsideFailedTransaction = 'E' };

enum string[uint] baseTypes = [
    // boolean types
    16 : "bool",
    // bytea types
    17 : "bytea",
    // character types
    18 : `"char"`, // "char" - 1 byte internal type
    1042 : "bpchar", // char(n) - blank padded
    1043 : "varchar",
    25 : "text",
    19 : "name",
    // numeric types
    21 : "int2",
    23 : "int4",
    20 : "int8",
    700 : "float4",
    701 : "float8",
    1700 : "numeric"
];

public:

enum PGType : uint
{
    OID = 26,
    NAME = 19,
    REGPROC = 24,
    BOOLEAN = 16,
    BYTEA = 17,
    CHAR = 18, // 1 byte "char", used internally in PostgreSQL
    BPCHAR = 1042, // Blank Padded char(n), fixed size
    VARCHAR = 1043,
    TEXT = 25,
    INT2 = 21,
    INT4 = 23,
    INT8 = 20,
    FLOAT4 = 700,
    FLOAT8 = 701
};

class ParamException : Exception
{
    this(string msg)
    {
        super(msg);
    }
}

/// Exception thrown on server error
class ServerErrorException: Exception
{
    /// Contains information about this _error. Aliased to this.
    ResponseMessage error;
    alias error this;
    
    this(string msg)
    {
        super(msg);
    }
    
    this(ResponseMessage error)
    {
        super(error.toString());
        this.error = error;
    }
}

/**
Class encapsulating errors and notices.

This class provides access to fields of ErrorResponse and NoticeResponse
sent by the server. More information about these fields can be found
$(LINK2 http://www.postgresql.org/docs/9.0/static/protocol-error-fields.html,here).
*/
class ResponseMessage
{
    private string[char] fields;
    
    private string getOptional(char type)
    {
        string* p = type in fields;
        return p ? *p : "";
    }
    
    /// Message fields
    @property string severity()
    {
        return fields['S'];
    }
    
    /// ditto
    @property string code()
    {
        return fields['C'];
    }
    
    /// ditto
    @property string message()
    {
        return fields['M'];
    }
    
    /// ditto
    @property string detail()
    {
        return getOptional('D');
    }
    
    /// ditto
    @property string hint()
    {
        return getOptional('H');
    }
    
    /// ditto
    @property string position()
    {
        return getOptional('P');
    }
    
    /// ditto
    @property string internalPosition()
    {
        return getOptional('p');
    }
    
    /// ditto
    @property string internalQuery()
    {
        return getOptional('q');
    }

    /// ditto
    @property string where()
    {
        return getOptional('W');
    }
    
    /// ditto
    @property string file()
    {
        return getOptional('F');
    }
    
    /// ditto
    @property string line()
    {
        return getOptional('L');
    }
    
    /// ditto
    @property string routine()
    {
        return getOptional('R');
    }
    
    /**
    Returns summary of this message using the most common fields (severity,
    code, message, detail, hint)
    */
    override string toString()
    {
        string s = severity ~ ' ' ~ code ~ ": " ~ message;
        
        string* detail = 'D' in fields;
        if (detail)
            s ~= "\nDETAIL: " ~ *detail;
        
        string* hint = 'H' in fields;
        if (hint)
            s ~= "\nHINT: " ~ *hint;
        
        return s;
    }
}

/**
Class representing connection to PostgreSQL server.
*/
class PGConnection
{
    private:
        Socket socket;
        PGStream stream;
        string[string] serverParams;
        int serverProcessID;
        int serverSecretKey;
        TransactionStatus trStatus;
        ulong lastPrepared = 0;
        uint[uint] arrayTypes;
        uint[][uint] compositeTypes;
        string[uint][uint] enumTypes;
        
        string reservePrepared()
        {
            synchronized (this)
            {
                return to!string(lastPrepared++);
            }
        }
        
        Message getMessage()
        {
            alias hton ntoh;

            char type;
            int len;
            
            stream.read(type); // message type
            stream.read(len); // message length, doesn't include type byte
        
            len = ntoh(len) - 4;
            
            ubyte[] msg = new ubyte[len];

            stream.read(msg);
            
            return Message(this, type, msg);
        }
        
        void sendStartupMessage(const string[string] params)
        {
            bool localParam(string key)
            {
                switch (key)
                {
                    case "host", "port", "password": return true;
                    default: return false;
                }
            }
            
            int len = 9; // length (int), version number (int) and parameter-list's delimiter (byte)
            
            foreach (key, value; params)
            {
                if (localParam(key))
                    continue;
                
                len += key.length + value.length + 2;
            }
            
            stream.write(len);
            stream.write(0x0003_0000); // version number 3
            
            foreach (key, value; params)
            {
                if (localParam(key))
                    continue;

                stream.writeCString(key);
                stream.writeCString(value);
            }
            
            stream.write(cast(ubyte)0);
        }
        
        void sendPasswordMessage(string password)
        {
            stream.write('p');
            stream.write(password.length + 5);
            stream.writeCString(password);
        }
        
        void sendParseMessage(string statementName, string query, uint[] oids)
        {
            int len = 4 + statementName.length + 1 + query.length + 1 + 2 + oids.length * 4;

            stream.write('P');
            stream.write(len);
            stream.writeCString(statementName);
            stream.writeCString(query);
            stream.write(cast(short)oids.length);
            
            foreach (oid; oids)
                stream.write(oid);
        }
        
        void sendCloseMessage(DescribeType type, string name)
        {
            stream.write('C');
            stream.write(4 + 1 + name.length + 1);
            stream.write(cast(char)type);
            stream.writeCString(name);
        }
        
        void sendBindMessage(string portalName, string statementName, PGParameters params)
        {
            int paramsLen = 0;
            
            foreach (param; params)
            {
                enforce(param.value.hasValue, new ParamException("Parameter $" ~ to!string(param.index) ~ " value is not initialized"));

                void checkParam(T)(int len)
                {
                    if (param.value != null)
                    {
                        enforce(param.value.convertsTo!T, new ParamException("Parameter's value is not convertible to " ~ T.stringof));
                        paramsLen += len;
                    }
                }
                
                /*final*/ switch (param.type)
                {
                    case PGType.INT2: checkParam!short(2); break;
                    case PGType.INT4: checkParam!int(4); break;
                    case PGType.INT8: checkParam!long(8); break;
                }
            }
            
            int len = 4 + portalName.length + 1 + statementName.length + 1 + 2 + 2 + 2 +
                params.length * 4 + paramsLen + 2 + 2;
            
            stream.write('B');
            stream.write(len);
            stream.writeCString(portalName);
            stream.writeCString(statementName);
            stream.write(cast(short)1); // one parameter format code
            stream.write(cast(short)1); // binary format
            stream.write(params.length);
            
            foreach (param; params)
            {
                if (param.value == null)
                {
                    stream.write(-1);
                    continue;
                }
                
                switch (param.type)
                {
                    case PGType.INT2:
                    {
                        stream.write(2);
                        stream.write(param.value.coerce!short);
                        break;
                    }
                    case PGType.INT4:
                    {
                        stream.write(4);
                        stream.write(param.value.coerce!int);
                        break;
                    }
                    case PGType.INT8:
                    {
                        stream.write(8);
                        stream.write(param.value.coerce!long);
                        break;
                    }
                }
            }
            
            stream.write(cast(short)1); // one result format code
            stream.write(cast(short)1); // binary format
        }
        
        enum DescribeType : char { Statement = 'S', Portal = 'P' }
        
        void sendDescribeMessage(DescribeType type, string name)
        {
            stream.write('D');
            stream.write(4 + 1 + name.length + 1);
            stream.write(cast(char)type);
            stream.writeCString(name);
        }
        
        void sendExecuteMessage(string portalName, int maxRows)
        {
            stream.write('E');
            stream.write(4 + portalName.length + 1 + 4);
            stream.writeCString(portalName);
            stream.write(maxRows);
        }
        
        void sendFlushMessage()
        {
            stream.write('H');
            stream.write(4);
        }

        void sendSyncMessage()
        {
            stream.write('S');
            stream.write(4);
        }
        
        ResponseMessage handleResponseMessage(Message msg)
        {
            enforce(msg.data.length >= 2);
            
            char ftype;
            string fvalue;
            ResponseMessage response = new ResponseMessage;
            
            while (msg.read(ftype), ftype > 0)
            {
                msg.readCString(fvalue);
                response.fields[ftype] = fvalue;
            }
            
            return response;
        }
        
        void prepare(string statementName, string query, PGParameters params)
        {
            sendParseMessage(statementName, query, params.getOids());
            sendFlushMessage();
            
        receive:
            
            Message msg = getMessage();
            
            switch (msg.type)
            {
                case 'E':
                {
                    // ErrorResponse
                    ResponseMessage response = handleResponseMessage(msg);
                    throw new ServerErrorException(response);
                }
                case '1':
                {
                    // ParseComplete
                    return;
                }
                default:
                {
                    // async notice, notification
                    goto receive;
                }
            }
        }
        
        PGFields bind(string portalName, string statementName, PGParameters params)
        {
            sendCloseMessage(DescribeType.Portal, portalName);
            sendBindMessage(portalName, statementName, params);
            sendDescribeMessage(DescribeType.Portal, portalName);
            sendFlushMessage();
            
        receive:
            
            Message msg = getMessage();
            
            switch (msg.type)
            {
                case 'E':
                {
                    // ErrorResponse
                    ResponseMessage response = handleResponseMessage(msg);
                    throw new ServerErrorException(response);
                }
                case '3':
                {
                    // CloseComplete
                    goto receive;
                }
                case '2':
                {
                    // BindComplete
                    goto receive;
                }
                case 'T':
                {
                    // RowDescription (response to Describe)
                    PGField[] fields;
                    short fieldCount;
                    short formatCode;
                    PGField fi;
                    
                    msg.read(fieldCount);
                    
                    fields.length = fieldCount;
                    
                    foreach (i; 0..fieldCount)
                    {
                        msg.readCString(fi.name);
                        msg.read(fi.tableOid);
                        msg.read(fi.index);
                        msg.read(fi.oid);
                        msg.read(fi.typlen);
                        msg.read(fi.modifier);
                        msg.read(formatCode);
                        
                        enforce(formatCode == 1, new Exception("Field's format code returned in RowDescription is not 1 (binary)"));
                        
                        fields[i] = fi;
                    }
                    
                    return cast(PGFields)fields;
                }
                case 'n':
                {
                    // NoData (response to Describe)
                    return new immutable(PGField)[0];
                }
                default:
                {
                    // async notice, notification
                    goto receive;
                }
            }
        }
        
        ulong executeNonQuery(string portalName, out uint oid)
        {
            ulong rowsAffected = 0;
            
            sendExecuteMessage(portalName, 0);
            sendSyncMessage();
            
        receive:
            
            Message msg = getMessage();
            
            switch (msg.type)
            {
                case 'E':
                {
                    // ErrorResponse
                    ResponseMessage response = handleResponseMessage(msg);
                    throw new ServerErrorException(response);
                }
                case 'D':
                {
                    // DataRow
                    finalizeQuery();
                    throw new Exception("This query returned rows.");
                }
                case 'C':
                {
                    // CommandComplete
                    string tag;
                    
                    msg.readCString(tag);
                    
                    auto s2 = lastIndexOf(tag, ' ');
                    if (s2 >= 0)
                    {
                        auto s1 = lastIndexOf(tag[0 .. s2], ' ');
                        if (s1 >= 0)
                        {
                            // INSERT oid rows
                            oid = parse!uint(tag[s1 + 1 .. s2]);
                        }
                        
                        rowsAffected = parse!ulong(tag[s2 + 1 .. $]);
                    }
                    
                    goto receive;
                }
                case 'I':
                {
                    // EmptyQueryResponse
                    goto receive;
                }
                case 'Z':
                {
                    // ReadyForQuery
                    return rowsAffected;
                }
                default:
                {
                    // async notice, notification
                    goto receive;
                }
            }
        }
        
        DBRow!Specs fetchRow(Specs...)(ref Message msg, ref PGFields fields)
        {
            alias DBRow!Specs Row;
            
            static if (Row.hasStaticLength)
            {
                alias Row.fieldTypes fieldTypes;
            
                static string genFieldAssigns() // CTFE
                {
                    string s = "";
                    
                    foreach (i, type; fieldTypes)
                    {
                        s ~= "msg.read(fieldLen);";
                        s ~= "if (fieldLen == -1)";
                        s ~= text("row.setNull!(", to!string(i), ")();");
                        s ~= "else\n";
                        s ~= text("row.set!(fieldTypes[", i, "], ", i, ")(",
                                  "msg.readBaseType!(fieldTypes[", i, "])(fields[", i, "].oid, fieldLen)",
                                  ");");
                    }
                    
                    return s;
                }
            }
            
            Row row;
            short fieldCount;
            int fieldLen;
            
            msg.read(fieldCount);
            
            static if (Row.hasStaticLength)
            {
                Row.checkReceivedFieldCount(fieldCount);
                mixin(genFieldAssigns);
            }
            else
            {
                row.setLength(fieldCount);
                
                foreach (i; 0 .. fieldCount)
                {
                    msg.read(fieldLen);
                    if (fieldLen == -1)
                        row.setNull(i);
                    else
                        row[i] = msg.readBaseType!(Row.ElemType)(fields[i].oid, fieldLen);
                }
            }
            
            return row;
        }
        
        void finalizeQuery()
        {
            Message msg;
            
            do
            {
                msg = getMessage();
                
                // TODO: process async notifications
            }
            while (msg.type != 'Z'); // ReadyForQuery
        }
        
        PGResultSet!Specs executeQuery(Specs...)(string portalName, ref PGFields fields)
        {
            PGResultSet!Specs result = new PGResultSet!Specs(this, &fetchRow!Specs);
            
            ulong rowsAffected = 0;
            
            sendExecuteMessage(portalName, 0);
            sendSyncMessage();
            
        receive:
            
            Message msg = getMessage();

            switch (msg.type)
            {
                case 'D':
                {
                    // DataRow
                    auto row = fetchRow!Specs(msg, fields);
                    //result.add(row);
                    
                    goto receive;
                }
                case 'C':
                {
                    // CommandComplete
                    string tag;
                    
                    msg.readCString(tag);
                    
                    auto s2 = lastIndexOf(tag, ' ');
                    if (s2 >= 0)
                    {
                        rowsAffected = parse!ulong(tag[s2 + 1 .. $]);
                    }
                
                    goto receive;
                }
                case 'I':
                {
                    // EmptyQueryResponse
                    throw new Exception("Query string is empty.");
                }
                case 's':
                {
                    // PortalSuspended
                    throw new Exception("Command suspending is not supported.");
                }
                case 'Z':
                {
                    // ReadyForQuery
                    return result;
                }
                case 'E':
                {
                    // ErrorResponse
                    ResponseMessage response = handleResponseMessage(msg);
                    throw new ServerErrorException(response);
                }
                default:
                {
                    // async notice, notification
                    goto receive;
                }
            }
            
            assert(0);
        }
        
    public:
        
        this()
        {
            socket = new TcpSocket;
            stream = new PGStream(socket);
        }

        /**
        Opens connection to server.
        
        Params:
        params = Associative array of string keys and values.
    
        Currently recognized parameters are:
        $(UL
            $(LI host - Host name or IP address of the server. Required.)
            $(LI port - Port number of the server. Defaults to 5432.)
            $(LI user - The database user. Required.)
            $(LI database - The database to connect to. Defaults to the user name.)
            $(LI options - Command-line arguments for the backend. (This is deprecated in favor of setting individual run-time parameters.))
        )
    
        In addition to the above, any run-time parameter that can be set at backend start time might be listed.
        Such settings will be applied during backend start (after parsing the command-line options if any).
        The values will act as session defaults.
        
        Examples:
        ---
        auto conn = new PGConnection;
        conn.open([
            "host" : "localhost",
            "database" : "test",
            "user" : "postgres",
            "password" : "postgres"
        ]);
        ---
        */
        void open(const string[string] params)
        {
            enforce("host" in params, new ParamException("Required parameter 'host' not found"));
            enforce("user" in params, new ParamException("Required parameter 'user' not found"));
            
            string[string] p = cast(string[string])params;
            
            ushort port = "port" in params? parse!ushort(p["port"]) : 5432;
            
            socket.connect(new InternetAddress(params["host"], port));
            sendStartupMessage(params);
            
        receive:
            
            Message msg = getMessage();
            
            switch (msg.type)
            {
                case 'E', 'N':
                {
                    // ErrorResponse, NoticeResponse
                    ResponseMessage response = handleResponseMessage(msg);
                    
                    if (msg.type == 'N')
                        goto receive;
                    
                    throw new ServerErrorException(response);
                }
                case 'R':
                {
                    // AuthenticationXXXX
                    enforce(msg.data.length >= 4);
                    
                    int atype;
                    
                    msg.read(atype);
                    
                    switch (atype)
                    {
                        case 0:
                        {
                            // authentication successful, now wait for another messages
                            goto receive;
                        }
                        case 3:
                        {
                            // clear-text password is required
                            enforce("password" in params, new ParamException("Required parameter 'password' not found"));
                            enforce(msg.data.length == 4);

                            sendPasswordMessage(params["password"]);
                            
                            goto receive;
                        }
                        case 5:
                        {
                            // MD5-hashed password is required, formatted as:
                            // "md5" + md5(md5(password + username) + salt)
                            // where md5() returns lowercase hex-string
                            enforce("password" in params, new ParamException("Required parameter 'password' not found"));
                            enforce(msg.data.length == 8);

                            ubyte[16] digest;
                            string password = "md5" ~ MD5toHex(MD5toHex(
                                params["password"], params["user"]), msg.data[4 .. 8]);
                            
                            sendPasswordMessage(password);
                            
                            goto receive;
                        }
                        default:
                        {
                            // non supported authentication type, close connection
                            socket.close();
                            throw new Exception("Unsupported authentication type");
                        }
                    }
                    
                    break;
                }
                case 'S':
                {
                    // ParameterStatus
                    enforce(msg.data.length >= 2);
                    
                    string pname, pvalue;

                    msg.readCString(pname);
                    msg.readCString(pvalue);
                    
                    serverParams[pname] = pvalue;
                    
                    goto receive;
                    
                    break;
                }
                case 'K':
                {
                    // BackendKeyData
                    enforce(msg.data.length == 8);
                        
                    msg.read(serverProcessID);
                    msg.read(serverSecretKey);
                    
                    goto receive;
                    
                    break;
                }
                case 'Z':
                {
                    // ReadyForQuery
                    enforce(msg.data.length == 1);
                    
                    msg.read(cast(char)trStatus);
                    
                    // check for validity
                    switch (trStatus)
                    {
                        case 'I', 'T', 'E': break;
                        default: throw new Exception("Invalid transaction status");
                    }
                    
                    // connection is opened and now it's possible to send queries
                    reloadAllTypes();
                    return;
                }
                default:
                {
                    // unknown message type, ignore it
                    goto receive;
                }
            }
        }

        /// Closes current connection to the server.
        void close()
        {
            socket.close();
        }
        
        /// Shorthand methods using temporary PGCommand. Semantics is the same as PGCommand's.
        ulong executeNonQuery(string query)
        {
            scope cmd = new PGCommand(this, query);
            return cmd.executeNonQuery();
        }

        /// ditto        
        PGResultSet!Specs executeQuery(Specs...)(string query)
        {
            scope cmd = new PGCommand(this, query);
            return cmd.executeQuery!Specs();
        }
        
        /// ditto
        DBRow!Specs executeRow(Specs...)(string query, throwIfMoreRows = true)
        {
            scope cmd = new PGCommand(this, query);
            return cmd.executeRow!Specs(throwIfMoreRows);
        }
        
        /// ditto
        T executeScalar(T)(string query, throwIfMoreRows = true)
        {
            scope cmd = new PGCommand(this, query);
            return cmd.executeScalar!T(throwIfMoreRows);
        }

        void reloadArrayTypes()
        {
            auto cmd = new PGCommand(this, "SELECT oid, typelem FROM pg_type WHERE typcategory = 'A'");
            auto result = cmd.executeQuery!(uint, "arrayOid", uint, "elemOid");
        
            arrayTypes = null;
            
            foreach (row; result)
            {
                arrayTypes[row.arrayOid] = row.elemOid;
            }
            
            arrayTypes.rehash;
        }
        
        void reloadCompositeTypes()
        {
            auto cmd = new PGCommand(this, "SELECT a.attrelid, a.atttypid FROM pg_attribute a JOIN pg_type t ON 
                                     a.attrelid = t.typrelid WHERE a.attnum > 0 ORDER BY a.attrelid, a.attnum");
            auto result = cmd.executeQuery!(uint, "typeOid", uint, "memberOid");
            
            compositeTypes = null;
            
            uint lastOid = 0;
            uint[]* memberOids;
            
            foreach (row; result)
            {
                if (row.typeOid != lastOid)
                {
                    compositeTypes[lastOid = row.typeOid] = new uint[0];
                    memberOids = &compositeTypes[lastOid];
                }
                
                *memberOids ~= row.memberOid;
            }
            
            compositeTypes.rehash;
        }
        
        void reloadEnumTypes()
        {
            auto cmd = new PGCommand(this, "SELECT enumtypid, oid, enumlabel FROM pg_enum ORDER BY enumtypid, oid");
            auto result = cmd.executeQuery!(uint, "typeOid", uint, "valueOid", string, "valueLabel");
            
            enumTypes = null;
            
            uint lastOid = 0;
            string[uint]* enumValues;
            
            foreach (row; result)
            {
                if (row.typeOid != lastOid)
                {
                    if (lastOid > 0)
                        (*enumValues).rehash;
                    
                    enumTypes[lastOid = row.typeOid] = null;
                    enumValues = &enumTypes[lastOid];
                }
                
                (*enumValues)[row.valueOid] = row.valueLabel;
            }
            
            if (lastOid > 0)
                (*enumValues).rehash;
            
            enumTypes.rehash;
        }
        
        void reloadAllTypes()
        {
            // todo: make simpler type lists, since we need only oids of types (without their members)
            reloadArrayTypes();
            reloadCompositeTypes();
            reloadEnumTypes();
        }
}

/// Class representing single query parameter
class PGParameter
{
    private PGParameters params;
    immutable short index;
    immutable PGType type;
    private Variant _value;
    
    /// Value bound to this parameter
    @property Variant value()
    {
        return _value;
    }
    /// ditto
    @property Variant value(Variant v)
    {
        params.changed = true;
        return _value = v;
    }
    
    private this(PGParameters params, short index, PGType type)
    {
        enforce(index > 0, new ParamException("Parameter's index must be > 0"));
        this.params = params;
        this.index = index;
        this.type = type;
    }
}

/// Collection of query parameters
class PGParameters
{
    private PGParameter[short] params;
    private PGCommand cmd;
    private bool changed;
    
    private uint[] getOids()
    {
        short[] keys = params.keys;
        sort(keys);
        
        uint[] oids = new uint[params.length];
        
        foreach (int i, key; keys)
        {
            oids[i] = params[key].type;
        }
        
        return oids;
    }
    
    ///
    @property short length()
    {
        return cast(short)params.length;
    }
    
    private this(PGCommand cmd)
    {
        this.cmd = cmd;
    }
    
    /**
    Creates and returns new parameter.
    Examples:
    ---
    // without spaces between $ and number
    auto cmd = new PGCommand(conn, "INSERT INTO users (name, surname) VALUES ($ 1, $ 2)");
    cmd.parameters.add(1, PGType.text).value = "John";
    cmd.parameters.add(2, PGType.text).value = "Doe";
    
    assert(cmd.executeNonQuery == 1);
    ---
    */
    PGParameter add(short index, PGType type)
    {
        enforce(!cmd.prepared, "Can't add parameter to prepared statement.");
        changed = true;
        return params[index] = new PGParameter(this, index, type);
    }
    
    // todo: remove()
    
    PGParameter opIndex(short index)
    {
        return params[index];
    }

    int opApply(int delegate(ref PGParameter param) dg)
    {
        int result = 0;

        foreach (param; params)
        {
            result = dg(param);
            
            if (result)
                break;
        }
        
        return result;
    }
}

/// Array of fields returned by the server
alias immutable(PGField)[] PGFields;

/// Contains information about fields returned by the server
struct PGField
{
    /// The field name.
    string name;
    /// If the field can be identified as a column of a specific table, the object ID of the table; otherwise zero.
    uint tableOid;
    /// If the field can be identified as a column of a specific table, the attribute number of the column; otherwise zero.
    short index;
    /// The object ID of the field's data type.
    uint oid;
    /// The data type size (see pg_type.typlen). Note that negative values denote variable-width types.
    short typlen;
    /// The type modifier (see pg_attribute.atttypmod). The meaning of the modifier is type-specific.
    int modifier;
}

/// Class encapsulating prepared or non-prepared statements (commands).
class PGCommand
{
    private PGConnection conn;
    private string _query;
    private PGParameters params;
    private PGFields _fields = null;
    private string preparedName;
    private uint _lastInsertOid;
    private bool prepared;
    
    /// List of parameters bound to this command
    @property PGParameters parameters()
    {
        return params;
    }
    
    /// List of fields that will be returned from the server. Available after successful call to bind().
    @property PGFields fields()
    {
        return _fields;
    }
    
    /**
    Checks if this is query or non query command. Available after successful call to bind().
    Returns: true if server returns at least one field (column). Otherwise false.
    */
    @property bool isQuery()
    {
        enforce(_fields !is null, new Exception("bind() must be called first"));
        return _fields.length > 0;
    }
    
    /// Returns: true if command is currently prepared, otherwise false.
    @property bool isPrepared()
    {
        return prepared;
    }
    
    /// Query assigned to this command.
    @property string query()
    {
        return _query;
    }
    /// ditto
    @property string query(string query)
    {
        enforce(!prepared, "Can't change query for prepared statement");
        return _query = query;
    }
    
    /// 
    @property uint lastInsertOid()
    {
        return _lastInsertOid;
    }
    
    this(PGConnection conn, string query = "")
    {
        this.conn = conn;
        _query = query;
        params = new PGParameters(this);
        _fields = new immutable(PGField)[0];
        preparedName = "";
        prepared = false;
    }
    
    /// Prepare this statement, i.e. cache query plan.
    void prepare()
    {
        preparedName = conn.reservePrepared();
        conn.prepare(preparedName, _query, params);
        prepared = true;
    }
    
    /// Unprepare this statement. Goes back to normal query planning.
    void unprepare()
    {
        preparedName = "";
        prepared = false;
    }
    
    /**
    Binds values to parameters and updates list of returned fields.
    
    This is normally done automatically, but it may be useful to check what fields
    would be returned from a query, before executing it.
    */
    void bind()
    {
        checkPrepared(false);
        _fields = conn.bind(preparedName, preparedName, params);
        params.changed = false;
    }
    
    private void checkPrepared(bool bind)
    {
        if (!prepared)
        {
            // use unnamed statement & portal
            conn.prepare("", _query, params);
            if (bind)
                _fields = conn.bind("", "", params);
            prepared = true;
        }
    }
    
    private void checkBound()
    {
        if (params.changed)
            bind();
    }
    
    /**
    Executes a non query command, i.e. query which doesn't return any rows. Commonly used with
    data manipulation commands, such as INSERT, UPDATE and DELETE.
    Examples:
    ---
    auto cmd = new PGCommand(conn, "DELETE * FROM table");
    auto deletedRows = cmd.executeNonQuery;
    cmd.query = "UPDATE table SET quantity = 1 WHERE price > 100";
    auto updatedRows = cmd.executeNonQuery;
    cmd.query = "INSERT INTO table VALUES(1, 50)";
    assert(cmd.executeNonQuery == 1);
    ---
    Returns: Number of affected rows.
    */
    ulong executeNonQuery()
    {
        checkPrepared(true);
        checkBound();
        return conn.executeNonQuery(preparedName, _lastInsertOid);
    }
    
    /**
    Executes query which returns row sets, such as SELECT command.
    Params:
    bufferedRows = Number of rows that may be allocated at the same time.
    Returns: InputRange of DBRow!Specs.
    */	
    PGResultSet!Specs executeQuery(Specs...)()
    {
        checkPrepared(true);
        checkBound();
        return conn.executeQuery!Specs(preparedName, _fields);
    }
    
    /**
    Executes query and returns only first row of the result.
    Params:
    throwIfMoreRows = If true, throws Exception when result contains more than one row.
    Examples:
    ---
    auto cmd = new PGCommand(conn, "SELECT 1, 'abc'");
    auto row1 = cmd.executeRow!(int, string); // returns DBRow!(int, string)
    assert(is(typeof(i[0]) == int) && is(typeof(i[1]) == string));
    auto row2 = cmd.executeRow; // returns DBRow!(Variant[])
    ---
    Throws: Exception if result doesn't contain any rows or field count do not match.
    Throws: Exception if result contains more than one row when throwIfMoreRows is true.
    */
    DBRow!Specs executeRow(Specs...)(throwIfMoreRows = true)
    {
        auto result = executeQuery!Specs();
        scope(exit) result.close();
        enforce(!result.empty(), "Result doesn't contain any rows.");
        auto row = result.front();
        if (throwIfMoreRows)
        {
            result.popFront();
            enforce(result.empty(), "Result contains more than one row.");
        }
        return row;
    }
    
    /**
    Executes query returning exactly one row and field. By default, returns Variant type.
    Params:
    throwIfMoreRows = If true, throws Exception when result contains more than one row.
    Examples:
    ---
    auto cmd = new PGCommand(conn, "SELECT 1");
    auto i = cmd.executeScalar!int; // returns int
    assert(is(typeof(i) == int));
    auto v = cmd.executeScalar; // returns Variant
    ---
    Throws: Exception if result doesn't contain any rows or if it contains more than one field.
    Throws: Exception if result contains more than one row when throwIfMoreRows is true.
    */
    T executeScalar(T = Variant)(bool throwIfMoreRows = true)
    {
        auto result = executeQuery!T();
        scope(exit) result.close();
        enforce(!result.empty(), "Result doesn't contain any rows.");
        T row = result.front();
        if (throwIfMoreRows)
        {
            result.popFront();
            enforce(result.empty(), "Result contains more than one row.");
        }
        return row;
    }
    
    /*
    TODO:
    executeScalar returning one first row and first column value
    executeArray returning array of row values from 1st column
    */
}

//alias PGResultSet!(Variant[]) PGResultSetUntyped;

/// Input range of DBRow!Specs
class PGResultSet(Specs...)
{
    alias DBRow!Specs Row;
    alias Row delegate(ref Message msg, ref PGFields fields) FetchRowDelegate;
    
    private FetchRowDelegate fetchRow;
    private PGConnection conn;
    private PGFields fields;
    private Row row;
    private Message nextMsg;
    
    private this(PGConnection conn, FetchRowDelegate dg)
    {
        this.conn = conn;
        this.fetchRow = dg;
    }
    
    pure nothrow bool empty()
    {
        return nextMsg.type != 'D';
    }
    
    void popFront()
    {
        if (nextMsg.type != 'D')
        {
            row = fetchRow(nextMsg, fields);
            nextMsg = conn.getMessage();
        }
    }
    
    pure nothrow Row front()
    {
        return row;
    }
    
    /// Closes current result set. It must be closed before issuing another query on the same connection.
    void close()
    {
    }
    
    int opApply(int delegate(ref Row row) dg)
    {
        int result = 0;

        while (!empty)
        {
            result = dg(row);
            
            if (result)
                break;
        }
        
        return result;
    }
    
    int opApply(int delegate(ref size_t i, ref Row row) dg)
    {
        int result = 0;
        
        uint i;
        //foreach (i, row; rows)
        {
            result = dg(i, row);
            
            //if (result)
                //break;
        }
        
        return result;
    }
}