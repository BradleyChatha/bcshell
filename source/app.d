import std, jcli;

TextBuffer          g_buffer;                   // Buffer used to display the shell
Layout              g_inLayout;                 // Layout used to display the shell
char[]              g_inputBuffer;              // Input buffer from the user
int                 g_cursorX;                  // X position of the cursor within the input buffer.
bool                g_isValidCommand;           // Whether the current g_commandSlice is a valid command.
const(char)[]       g_commandSlice;             // The part of g_inputBuffer that contains the command.
string              g_partialCommandMatch;      // The full string of any partially match command.
ExeInfo             g_foundCommand;             // The information for any fully matched command.
string[]            g_commandHistory;           // Command history stack.
int                 g_commandHistoryCursor;     // Where the user currently is in the history stack.
Resolver!ExeInfo    g_resolver;                 // Command resolver. This is implemented as a Trie, with support for matching partial commands - exactly what any shell would want!
ArgInfo[]           g_args;                     // Information about the arguments held within g_inputBuffer.
string              g_argAutocomplete;          // Suggested autocomplete for current arg.
size_t              g_argAutocompleteOffset;    // Offset to apply when finding arg autocomplete.

struct ExeInfo
{
    string fullPath;
    void function(ExeInfo) onExecute;
}

struct ArgInfo
{
    string value;
    int start;
}

void main()
{
    version(unittest){}
    else
    {
        // Initial setup
        Console.attach(false);
        scope(exit) Console.detach();
        g_resolver = new typeof(g_resolver)();
        addInternalCommands();
        readPATH();
        g_buffer = Console.createTextBuffer();
        g_inLayout = Layout(Rect(
            0, Console.screenSize.y-1, Console.screenSize.x, Console.screenSize.y
        ), Console.screenSize.x, 1);

        // Event loop
        while(Console.isAttached)
        {
            Console.processEvents((&update).toDelegate);
            render();
        }
    }
}

void update(ConsoleEvent event)
{
    event.match!(
        (ConsoleKeyEvent k) => onKey(k),
        (_) {}
    );

    findCommand();
    findArgs();
    findArgAutocomplete();
}

void findCommand()
{
    // Skip initial whitespace
    size_t commandSliceLen;
    while(commandSliceLen < g_inputBuffer.length && g_inputBuffer[commandSliceLen] != ' ')
        commandSliceLen++;
    
    // See if we can match the given command to any known commands.
    g_commandSlice = g_inputBuffer[0..commandSliceLen];
    const result = g_resolver.resolve([cast(string)g_commandSlice]);
    if(result.kind == result.Kind.full) // If so, set some vars
    {
        g_isValidCommand = true;
        g_partialCommandMatch = null;
        g_foundCommand = result.fullMatchChain[$-1].userData;
    }
    else if(result.kind == result.Kind.partial) // For partial matches, find the shortest partial match and display it to the user.
    {
        g_isValidCommand = false;
        
        string shortestMatch = result.partialMatches[0].fullMatchString;
        foreach(p; result.partialMatches[1..$])
        {
            if(p.fullMatchString.length < shortestMatch.length)
                shortestMatch = p.fullMatchString;
        }

        g_partialCommandMatch = shortestMatch;
        g_foundCommand = ExeInfo.init;
    }
    else // Otherwise we have no match, so set the appropriate vars.
    {
        g_isValidCommand = false;
        g_partialCommandMatch = null;
        g_foundCommand = ExeInfo.init;
    }
}

void findArgs()
{
    import std.ascii : isWhite;

    // Skip over the command part of the input buffer.
    const argsSlice = g_inputBuffer[g_commandSlice.length..$];
    if(!argsSlice.length)
        return;

    g_args.length = 0;

    Appender!(char[]) builder;

    // Find the first non-white character.
    size_t start = 0;
    while(start < argsSlice.length && argsSlice[start].isWhite)
        start++;
    size_t i = start;
    g_args ~= ArgInfo(null, start.to!int);

    void pushArg()
    {
        // Push whatever's in `builder`, clear it, then find the next non-white character.
        g_args[$-1].value = builder.data.dup;
        builder.clear();

        while(i < argsSlice.length && argsSlice[i].isWhite)
            i++;
        start = i;
        g_args ~= ArgInfo(null, start.to!int);
    }

    // Keep reading non-white chars, then push on a white char.
    // TODO: $VAR, ${script}, "abc", and "a\"bc" support.
    for(; i < argsSlice.length; i++)
    {
        if(argsSlice[i].isWhite)
        {
            builder.put(argsSlice[start..i]);
            pushArg();
        }
    }

    // Make sure we don't miss off the end.
    if(start < i && i <= argsSlice.length)
    {
        builder.put(argsSlice[start..i]);
        pushArg();
    }
}

void onKey(ConsoleKeyEvent event)
{
    if(!event.isDown)
        return;

    if(event.key == ConsoleKey.escape)
        Console.detach();
    else if(event.key == ConsoleKey.left && g_cursorX > 0)
        g_cursorX--;
    else if(event.key == ConsoleKey.right && g_cursorX < g_inputBuffer.length)
        g_cursorX++;
    else if(event.key == ConsoleKey.back && g_cursorX > 0 && g_inputBuffer.length)
    {
        for(auto i = g_cursorX; i < g_inputBuffer.length; i++)
            g_inputBuffer[i-1] = g_inputBuffer[i];
        g_inputBuffer.length--;
        g_cursorX--;
    }
    else if(event.key == ConsoleKey.del && g_cursorX < g_inputBuffer.length)
    {
        for(auto i = g_cursorX; i < g_inputBuffer.length - 1; i++)
            g_inputBuffer[i] = g_inputBuffer[i+1];
        g_inputBuffer.length--;
    }
    else if(event.key == ConsoleKey.enter)
    {
        writeln();
        if(g_foundCommand.onExecute)
            g_foundCommand.onExecute(g_foundCommand);
        g_commandHistory ~= g_inputBuffer.idup;
        g_inputBuffer.length = 0;
        g_cursorX = 0;
        g_commandHistoryCursor = 0;
        g_args.length = 0;
        g_argAutocomplete = null;
    }
    else if(event.key == ConsoleKey.tab)
        tabComplete();
    else if(event.key == ConsoleKey.up)
    {
        if(event.specialKeys && event.SpecialKey.shift)
        {
            if(g_argAutocompleteOffset != 0)
                g_argAutocompleteOffset--;
        }
        else if(g_commandHistoryCursor < g_commandHistory.length)
        {
            g_inputBuffer = g_commandHistory[$-++g_commandHistoryCursor].dup;
            g_cursorX = g_inputBuffer.length.to!int;
        }
    }
    else if(event.key == ConsoleKey.down)
    {
        if(event.specialKeys && event.SpecialKey.shift)
        {
            g_argAutocompleteOffset++;
        }
        else if(g_commandHistoryCursor > 1)
        {
            g_inputBuffer = g_commandHistory[$-(--g_commandHistoryCursor)].dup;
            g_cursorX = g_inputBuffer.length.to!int;
        }
    }
    else
    {
        // Put any visible characters into the input buffer.
        import std.uni : isControl;
        if(isControl(event.charAsAscii))
            return;
        
        // Either append or insert the character, depending on where the cursor is.
        if(g_cursorX >= g_inputBuffer.length)
            g_inputBuffer ~= event.charAsAscii;
        else
        {
            g_inputBuffer.length++;
            for(auto i = g_inputBuffer.length-1; i > g_cursorX; i--)
                g_inputBuffer[i] = g_inputBuffer[i-1];

            g_inputBuffer[g_cursorX] = event.charAsAscii;
        }
        g_cursorX++;
    }
}

void render()
{
    const visualCursor = renderInput();
    Console.hideCursor(); // Stops a weird visual thing terminals like to do with the cursor.
    g_buffer.refresh();
    Console.showCursor();
    Console.setCursor(visualCursor, Console.screenSize.y);
}

uint renderInput()
{
    import core.sys.windows.winbase, core.sys.windows.lmcons, core.sys.windows.winsock2;
    import core.stdc.string;

    // Construct the prefix in the form: USER@HOST CWD>
    // If the CWD is longer than 30 chars, try to compress it a bit.
    auto cwd = getcwd()~">";
    if(cwd.length >= 30)
        cwd = cwd.pathSplitter.map!(p => p.length ? p[0..max($/2, 1)] : "").joiner("/").array.to!string.idup~">";

    char[UNLEN+1] username;
    uint usernameLen = username.length;
    GetUserNameA(username.ptr, &usernameLen);

    char[UNLEN+1] hostname;
    gethostname(hostname.ptr, hostname.length.to!int);

    const prefix = username[0..usernameLen-1]~"@"~hostname[0..strlen(hostname.ptr)];

    // Clear the bottom-most row of any previous input.
    BorderWidgetBuilder()
        .withBlockArea(Rect(0, 0, Console.screenSize.x, 1))
        .build()
        .render(g_inLayout, g_buffer);

    // Display the prefix and CWD
    TextWidgetBuilder()
        .withBlockArea(Rect(0, 0, Console.screenSize.x, 1))
        .withText(prefix.idup)
        .withStyle(AnsiStyleSet().fg(AnsiColour(Ansi4BitColour.cyan)))
        .build()
        .render(g_inLayout, g_buffer);
    TextWidgetBuilder()
        .withBlockArea(Rect(prefix.length.to!int+1, 0, Console.screenSize.x, 1))
        .withText(cwd)
        .withStyle(AnsiStyleSet().fg(AnsiColour(Ansi4BitColour.brightGreen)))
        .build()
        .render(g_inLayout, g_buffer);

    // If we have a partial match, display that "below" the user's input.
    import std.ascii : isWhite;
    if(!g_isValidCommand && g_partialCommandMatch.length && g_inputBuffer.length && !g_inputBuffer.all!isWhite)
    {
        TextWidgetBuilder()
            .withBlockArea(Rect((prefix.length + cwd.length).to!int + 2, 0, Console.screenSize.x, 1))
            .withText(cast(string)g_partialCommandMatch)
            .withStyle(AnsiStyleSet().fg(AnsiColour(Ansi4BitColour.brightBlack)))
            .build()
            .render(g_inLayout, g_buffer);
    }

    // Ditto for the argument
    if(g_argAutocomplete.length)
    {
        size_t _1;
        const arg = currArg(_1);
        TextWidgetBuilder()
            .withBlockArea(Rect((prefix.length + cwd.length + g_commandSlice.length + arg.start).to!int + 2, 0, Console.screenSize.x, 1))
            .withText(g_argAutocomplete)
            .withStyle(AnsiStyleSet().fg(AnsiColour(Ansi4BitColour.brightBlack)))
            .build()
            .render(g_inLayout, g_buffer);
    }

    // Display the user's input.
    TextWidgetBuilder()
        .withBlockArea(Rect((prefix.length + cwd.length).to!int + 2, 0, Console.screenSize.x, 1))
        .withText(cast(string)g_commandSlice)
        .withStyle(g_isValidCommand ? AnsiStyleSet().fg(AnsiColour(Ansi4BitColour.cyan)) : AnsiStyleSet().fg(AnsiColour(Ansi4BitColour.red)))
        .build()
        .render(g_inLayout, g_buffer);
    TextWidgetBuilder()
        .withBlockArea(Rect((prefix.length + cwd.length + g_commandSlice.length).to!int + 2, 0, Console.screenSize.x, 1))
        .withText(cast(string)g_inputBuffer[g_commandSlice.length..$])
        .withStyle(AnsiStyleSet().fg(AnsiColour(Ansi4BitColour.white)))
        .build()
        .render(g_inLayout, g_buffer);

    // Highlight the current argument.
    size_t _;
    const arg = currArg(_);
    TextWidgetBuilder()
        .withBlockArea(Rect((prefix.length + cwd.length + g_commandSlice.length + arg.start).to!int + 2, 0, Console.screenSize.x, 1))
        .withText(arg.value)
        .withStyle(AnsiStyleSet().fg(AnsiColour(Ansi4BitColour.yellow)))
        .build()
        .render(g_inLayout, g_buffer);

    return (prefix.length + cwd.length).to!int + 3 + g_cursorX;
}

void addInternalCommands()
{
    g_resolver.add(["echo"], ExeInfo("echo", (_)
    {
        foreach(arg; g_args)
            std.stdio.write(arg.value, " ");
        writeln();
    }), null);

    g_resolver.add(["cd"], ExeInfo("cd", (_)
    {
        try chdir(g_args[0].value);
        catch(Exception ex) writeln('\n', ex.msg);
        onChdir();
    }), null);
}

void doExecute(ExeInfo info)
{
    writeln();

    try
    {
        auto pipes = pipeProcess([info.fullPath] ~ g_args.map!(a => a.value).filter!(a => a.length).array, Redirect.stdout | Redirect.stderrToStdout);

        char[1] buffer;
        auto slice = pipes.stdout.rawRead(buffer);
        while(slice.length)
        {
            scope(exit) slice = pipes.stdout.rawRead(buffer);
            stdout.write(slice);
        }
    }
    catch(Exception ex)
    {
        writeln(ex.msg);
    }
}

void readPATH()
{
    const PATH = environment.get("PATH");
    auto splits = PATH.splitter(";");

    foreach(split; splits)
    {
        try
        {
            foreach(string file; dirEntries(split, SpanMode.shallow).filter!(f => f.isFile))
            {
                if(file.endsWith(".exe"))
                {
                    g_resolver.add([file.baseName], ExeInfo(file, &doExecute), null);
                    g_resolver.add([file.baseName(".exe")], ExeInfo(file, &doExecute), null);
                }
            }
        }
        catch(Exception ex)
        {
        }
    }
}

void onChdir()
{

}

ArgInfo currArg(out size_t index)
{
    if(!g_args.length)
        return ArgInfo.init;

    const cursor = g_cursorX - g_commandSlice.length;

    foreach(i, a; g_args)
    {
        auto start = a.start;
        if(start >= cursor && i != 0)
        {
            index = i-1;
            return g_args[i-1];
        }
    }

    auto actualArgs = g_args[0..$-1];
    if(actualArgs.length)
    {
        index = actualArgs.length - 1;
        return actualArgs[$-1];
    }
    else
        return ArgInfo.init;
}

void tabComplete()
{
    if(g_args.length == 0)
    {
        g_inputBuffer = g_partialCommandMatch.dup;
        g_cursorX = g_inputBuffer.length.to!int;
    }

    size_t _1;
    const arg = currArg(_1);
    
    if(g_argAutocomplete.length && g_argAutocomplete.length > arg.value.length)
    {

        const diff = g_argAutocomplete.length - arg.value.length;
        g_inputBuffer.length += diff;
        for(auto i = g_inputBuffer.length-1; i > g_cursorX; i--)
            g_inputBuffer[i] = g_inputBuffer[i-1];

        g_inputBuffer[g_cursorX..g_cursorX+diff] = g_argAutocomplete[$-diff..$];
        g_cursorX += diff;    
    }
}

void findArgAutocomplete()
{
    size_t _1;
    const arg = currArg(_1);

    g_argAutocomplete = null;

    if(arg.value is null)
        return;

    auto resolver = new Resolver!string();
    const path = arg.value.isAbsolute
            ? arg.value
            : buildPath(getcwd(), arg.value);
    const offset = arg.value.isAbsolute || arg.value == "/"
            ? 0
            : getcwd().length + 1; // Skip leading "/"

    // Add files/folders relative to the arg, assuming the arg is a path.
    try
    {
        if(path.exists)
        {
            foreach(entry; dirEntries(path, SpanMode.shallow))
                resolver.add([entry.name.replace("\\", "/")[offset..$]], entry.name, null);
        }
        else
        {
            foreach(entry; dirEntries(path.dirName, SpanMode.shallow))
                resolver.add([entry.name.replace("\\", "/")[offset..$]], entry.name, null);
        }
    }
    catch(Exception ex){ }

    // Perform the resolution.
    auto result = resolver.resolve([arg.value]);
    if(result.kind == result.Kind.partial && result.partialMatches.length)
    {
        auto strings = result.partialMatches.map!(p => p.fullMatchString).array;
        strings.sort!"a.length < b.length";

        g_argAutocomplete = strings[min(strings.length-1, g_argAutocompleteOffset)];
        if(!g_argAutocomplete.startsWith(arg.value))
            g_argAutocomplete = null;
    }
}