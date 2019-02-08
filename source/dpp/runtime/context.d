/**
   The context the translation happens in, to avoid global variables
 */
module dpp.runtime.context;

alias LineNumber = size_t;

// A function or global variable
struct Linkable {
    LineNumber lineNumber;
    string mangling;
}

enum Language {
    C,
    Cpp,
}


/**
   Context for the current translation, to avoid global variables
 */
struct Context {

    import dpp.runtime.options: Options;
    import dpp.ast.node: Node;
    import clang: Type, AccessSpecifier;

    alias SeenNodes = bool[NodeId];

    /**
       The lines of output so far. This is needed in order to fix
       any name collisions between functions or variables with aggregates
       such as structs, unions and enums.
     */
    private string[] lines;

    /**
       Structs can be anonymous in C, and it's even common
       to typedef them to a name. We come up with new names
       that we track here so as to be able to properly translate
       those typedefs.
    */
    private string[Node.Hash] _nickNames;

    /**
       Remembers the seen struct pointers so that if any are undeclared in C,
       we do so in D at the end.
     */
    private bool[string] _fieldStructSpellings;

    /**
       Remembers the field spellings in aggregates in case we need to change any
       of them.
     */
    private LineNumber[string] _fieldDeclarations;

    /**
       All the aggregates that have been declared
     */
    private bool[string] _aggregateDeclarations;

    /**
       A linkable is a function or a global variable.  We remember all
       the ones we saw here so that if there's a name clash we can
       come back and fix the declarations after the fact with
       pragma(mangle).
     */
    private Linkable[string] _linkableDeclarations;

    /**
       All the function-like macros that have been declared
     */
    private bool[string] _functionMacroDeclarations;

    /**
       Remember all the macros already defined
     */
    private bool[string] _macros;

    /**
       All previously seen cursors
     */
    private SeenNodes _seenNodes;

    AccessSpecifier accessSpecifier = AccessSpecifier.Public;

    /// Command-line options
    Options options;

    /*
      Remember all declared types so that C-style casts can be recognised
     */
    private string[] _types = [
        `void ?\*`,
        `char`, `unsigned char`, `signed char`, `short`, `unsigned short`,
        `int`, `unsigned`, `unsigned int`, `long`, `unsigned long`, `long long`,
        `unsigned long long`, `float`, `double`, `long double`,
    ];

    /// to generate unique names
    private int _anonymousIndex;

    private string[] _namespaces;

    Language language;

    this(Options options, in Language language) @safe pure {
        this.options = options;
        this.language = language;
    }

    ref Context indent() @safe pure return {
        options = options.indent;
        return this;
    }

    string indentation() @safe @nogc pure const {
        return options.indentation;
    }

    void setIndentation(in string indentation) @safe pure {
        options.indentation = indentation;
    }

    void log(A...)(auto ref A args) const {
        import std.functional: forward;
        options.log(forward!args);
    }

    void indentLog(A...)(auto ref A args) const {
        import std.functional: forward;
        options.indent.log(forward!args);
    }

    bool debugOutput() @safe @nogc pure nothrow const {
        return options.debugOutput;
    }

    bool hasSeen(in Node node) @safe pure nothrow const {
        return cast(bool) (NodeId(node) in _seenNodes);
    }

    void rememberNode(in Node node) @safe pure nothrow {
        import clang: Cursor;
        // EnumDecl can have no spelling but end up defining an enum anyway
        // See "it.compile.projects.double enum typedef"
        if(node.spelling != "" || node.kind == Cursor.Kind.EnumDecl)
            _seenNodes[NodeId(node)] = true;
    }

    string translation() @safe pure nothrow const {
        import std.array: join;
        return lines.join("\n");
    }

    void writeln(in string line) @safe pure nothrow {
        lines ~= line.dup;
    }

    void writeln(in string[] lines) @safe pure nothrow {
        this.lines ~= lines;
    }

    // remember a function or variable declaration
    string rememberLinkable(in Node node) @safe pure nothrow {
        import dpp.translation.dlang: maybeRename;

        const spelling = maybeRename(node, this);
        // since linkables produce one-line translations, the next
        // will be the linkable
        _linkableDeclarations[spelling] = Linkable(lines.length, node.mangling);

        return spelling;
    }

    void fixNames() @safe pure {
        declareUnknownStructs;
        fixLinkables;
        fixFields;
    }

    void fixLinkables() @safe pure {
        foreach(declarations; [_aggregateDeclarations, _functionMacroDeclarations]) {
            foreach(name, _; declarations) {
                // if there's a name clash, fix it
                auto clashingLinkable = name in _linkableDeclarations;
                if(clashingLinkable) {
                    resolveClash(lines[clashingLinkable.lineNumber], name, clashingLinkable.mangling);
                }
            }
        }
    }

    void fixFields() @safe pure {

        import dpp.translation.dlang: pragmaMangle, rename;
        import std.string: replace;

        foreach(spelling, lineNumber; _fieldDeclarations) {
            if(spelling in _aggregateDeclarations) {
                lines[lineNumber] = lines[lineNumber]
                    .replace(spelling ~ `;`, rename(spelling, this) ~ `;`);
            }
        }
    }

    /**
       Tells the context to remember a struct type encountered in an aggregate field.
       Typically this will be a pointer to a structure but it could also be the return
       type or parameter types of a function pointer field. This is (surprisingly!)
       perfectly valid C code, even though `Foo` is never declared anywhere:
       ----------------------
       struct Foo* fun(void);
       ----------------------
       See issues #22 and #24
     */
    void rememberFieldStruct(in string typeSpelling) @safe pure {
        _fieldStructSpellings[typeSpelling] = true;
    }

    /**
       In C it's possible for a struct field name to have the same name as a struct
       because of elaborated names. We remember them here in case we need to fix them.
     */
    void rememberField(in string spelling) @safe pure {
        _fieldDeclarations[spelling] = lines.length;
    }

    /**
       Remember this aggregate cursor
     */
    void rememberAggregate(in Node node) @safe pure {
        const spelling = spellingOrNickname(node);
        _aggregateDeclarations[spelling] = true;
        rememberType(spelling);
    }

    /**
       If unknown structs show up in functions or fields (as a pointer),
        define them now so the D file can compile
        See `it.c.compile.delayed`.
    */
    void declareUnknownStructs() @safe pure {
        foreach(name, _; _fieldStructSpellings) {
            if(name !in _aggregateDeclarations) {
                log("Could not find '", name, "' in aggregate declarations, defining it");
                writeln("struct " ~ name ~ ";");
                _aggregateDeclarations[name] = true;
            }
        }
    }

    const(typeof(_aggregateDeclarations)) aggregateDeclarations() @safe pure nothrow const {
        return _aggregateDeclarations;
    }

    /// return the spelling if it exists, or our made-up nickname for it if not
    string spellingOrNickname(in Node node) @safe pure {
        import dpp.translation.dlang: rename, isKeyword;
        if(node.spelling == "") return nickName(node);
        return node.spelling.isKeyword ? rename(node.spelling, this) : node.spelling;
    }

    private string nickName(in Node node) @safe pure {
        if(node.hash !in _nickNames) {
            auto nick = newAnonymousTypeName;
            _nickNames[node.hash] = nick;
        }

        return _nickNames[node.hash];
    }

    private string newAnonymousTypeName() @safe pure {
        import std.conv: text;
        return text("_Anonymous_", _anonymousIndex++);
    }

    string newAnonymousMemberName() @safe pure {
        import std.string: replace;
        return newAnonymousTypeName.replace("_A", "_a");
    }

    private void resolveClash(ref string line, in string spelling, in string mangling) @safe pure const {
        import dpp.translation.dlang: pragmaMangle;
        line = `    ` ~ pragmaMangle(mangling) ~ replaceSpelling(line, spelling);
    }

    private string replaceSpelling(in string line, in string spelling) @safe pure const {
        import dpp.translation.dlang: rename;
        import std.array: replace;
        return line
            .replace(spelling ~ `;`, rename(spelling, this) ~ `;`)
            .replace(spelling ~ `(`, rename(spelling, this) ~ `(`)
            ;
    }

    void rememberType(in string type) @safe pure nothrow {
        _types ~= type;
    }

    /// Matches a C-type cast
    auto castRegex() @safe const {
        import std.array: join, array;
        import std.regex: regex;
        import std.algorithm: map;
        import std.range: chain;

        // const and non const versions of each type
        const typesConstOpt = _types.map!(a => `(?:const )?` ~ a).array;

        const typeSelectionStr =
            chain(typesConstOpt,
                  // pointers thereof
                  typesConstOpt.map!(a => a ~ ` ?\*`))
            .join("|");

        // parens and a type inside, where "a type" is any we know about
        const regexStr = `\(( *?(?:` ~ typeSelectionStr ~ `) *?)\)`;

        return regex(regexStr);
    }

    void rememberMacro(in Node node) @safe pure {
        _macros[node.spelling] = true;
        if(node.isMacroFunction)
            _functionMacroDeclarations[node.spelling] = true;
    }

    bool macroAlreadyDefined(in Node node) @safe pure const {
        return cast(bool) (node.spelling in _macros);
    }

    void pushNamespace(in string ns) @safe pure nothrow {
        _namespaces ~= ns;
    }

    void popNamespace(in string ns) @safe pure nothrow {
        _namespaces = _namespaces[0 .. $-1];
    }

    // returns the current namespace so it can be deleted
    // from translated names
    string namespace() @safe pure nothrow const {
        import std.array: join;
        return _namespaces.join("::");
    }

    /// If this cursor is from one of the ignored namespaces
    bool isFromIgnoredNs(in Type type) @safe const {
        import std.algorithm: canFind, any;
        return options.ignoredNamespaces.any!(a => type.spelling.canFind(a ~ "::"));
    }
}


// to identify a cursor
private struct NodeId {
    import dpp.ast.node: Node;
    import clang: Cursor, Type;

    string cursorSpelling;
    Cursor.Kind cursorKind;
    string typeSpelling;
    Type.Kind typeKind;

    this(in Node node) @safe pure nothrow {
        cursorSpelling = node.spelling;
        cursorKind = node.kind;
        typeSpelling = node.type.spelling;
        typeKind = node.type.kind;
    }
}
