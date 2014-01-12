module Readline
    using Terminals

    import Terminals: raw!, width, height, cmove, Rect, Size, getX, 
                      getY, clear_line, beep

    import Base: ensureroom, peek

    abstract TextInterface 

    export run_interface, Prompt, ModalInterface, transition, reset_state, edit_insert

    immutable ModalInterface <: TextInterface
        modes
    end

    type MIState
        interface::ModalInterface
        current_mode
        aborted::Bool
        mode_state
    end

    type Mode <: TextInterface

    end

    type Prompt <: TextInterface
        prompt
        first_prompt
        prompt_color::ASCIIString
        keymap_func
        keymap_func_data
        input_color
        complete
        on_enter
        on_done
        hist
    end

    immutable InputAreaState
        num_rows::Int64
        curs_row::Int64
    end

    type PromptState
        terminal::TextTerminal
        p::Prompt
        input_buffer::IOBuffer
        ias::InputAreaState
        indent::Int
    end

    input_string(s::PromptState) = bytestring(pointer(s.input_buffer.data),s.input_buffer.ptr-1)

    abstract HistoryProvider
    abstract CompletionProvider

    type EmptyCompletionProvider <: CompletionProvider
    end

    type EmptyHistoryProvider <: HistoryProvider
    end

    reset_state(::EmptyHistoryProvider) = nothing

    completeLine(c::EmptyCompletionProvider,s) = []

    terminal(s::IO) = s
    terminal(s::PromptState) = s.terminal

    for f in [:terminal,:edit_insert,:on_enter,:add_history,:buffer,:edit_backspace,:(Base.isempty),
            :replace_line,:refreshMultiLine,:input_string,:completeLine,:edit_move_left,:edit_move_right,
            :update_display_buffer]
        @eval ($f)(s::MIState,args...) = $(f)(s.mode_state[s.current_mode],args...)
    end

    function common_prefix(completions)
        ret = ""
        i = nexti = 1
        cc,nexti = next(completions[1],1)
        while true
            for c in completions
                if i > length(c) || c[i] != cc
                    return ret
                end
            end
            ret = ret*string(cc)
            if i >= length(completions[1])
                return ret
            end
            i = nexti
            cc,nexti = next(completions[1],i)
        end
    end

    function completeLine(s::PromptState)
        (completions,partial) = completeLine(s.p.complete,s)
        if length(completions) == 0
            beep(Readline.terminal(s))
        elseif length(completions) == 1
            # Replace word by completion
            prev_pos = position(s.input_buffer)
            seek(s.input_buffer,prev_pos-sizeof(partial))
            edit_replace(s,position(s.input_buffer),prev_pos,completions[1])
        else
            p = common_prefix(completions)
            if length(p) > 0 && p != partial
                # All possible completions share the same prefix, so we might as
                # well complete that
                prev_pos = position(s.input_buffer)
                seek(s.input_buffer,prev_pos-sizeof(partial))
                edit_replace(s,position(s.input_buffer),prev_pos,p)
            else
                # Show available completions
                colmax = maximum(map(length,completions))
                num_cols = div(width(Readline.terminal(s)),colmax+2)
                entries_per_col = div(length(completions),num_cols)+1
                println(Readline.terminal(s))
                for row = 1:entries_per_col
                    for col = 0:num_cols
                        idx = row + col*entries_per_col
                        if idx <= length(completions)
                            cmove_col(Readline.terminal(s),(colmax+2)*col)
                            print(Readline.terminal(s),completions[idx])
                        end
                    end
                    println(Readline.terminal(s))
                end
            end
        end
    end

    clear_input_area(s) = (clear_input_area(s.terminal,s.ias); s.ias = InputAreaState(0,0))
    function clear_input_area(terminal,state::InputAreaState)
        #println(s.curs_row)
        #println(s.num_rows)

        # Go to the last line
        if state.curs_row < state.num_rows
            cmove_down(terminal,state.num_rows-state.curs_row)
        end

        # Clear lines one by one going up
        for j=0:(state.num_rows - 2)
            clear_line(terminal)
            cmove_up(terminal)
        end

        # Clear top line
        clear_line(terminal)       
    end 

    prompt_string(s::PromptState) = s.p.prompt
    prompt_string(s::String) = s

    refreshMultiLine(s::PromptState) = s.ias = refreshMultiLine(s.terminal,buffer(s),s.ias,s,indent=s.indent)

    function refreshMultiLine(terminal,buf,state::InputAreaState,prompt = "";indent = 0)
        cols = width(terminal)

        clear_input_area(terminal,state)

        curs_row = -1 #relative to prompt
        curs_col = -1 #absolute
        curs_pos = -1 # 1 - based column position of the cursor
        cur_row = 0
        buf_pos = position(buf)
        line_pos = buf_pos
        # Write out the prompt string
        write_prompt(terminal,prompt)
        prompt = prompt_string(prompt)

        seek(buf,0)

        llength = 0

        l=""

        # Now go through the buffer line by line
        while cur_row == 0 || (!isempty(l) && l[end] == '\n')
            l = readline(buf)
            cur_row += 1
            # We need to deal with UTF8 characters. Since the IOBuffer is a bytearray, we just count bytes
            llength = length(l)
            plength = length(prompt)
            slength = length(l.data)
            pslength = length(prompt.data)
            if cur_row == 1 #First line 
                if line_pos <= slength
                    num_chars = length(l[1:line_pos])
                    curs_row = div(plength+num_chars-1,cols)+1
                    curs_pos = (plength+num_chars-1)%cols+1
                end
                cur_row += div(plength+llength-1,cols)
                line_pos -= slength
                write(terminal,l)
            else
                # We expect to be line after the last valid output line (due to
                # the '\n' at the end of the previous line)
                if curs_row == -1
                    if line_pos < slength
                        num_chars = length(l[1:line_pos])
                        curs_row = cur_row+div(indent+num_chars-1,cols)
                        curs_pos = (indent+num_chars-1)%cols+1
                    end
                    line_pos -= slength #'\n' gets an extra pos
                    cur_row += div(llength+indent-1,cols)
                    cmove_col(terminal,indent+1)
                    write(terminal,l)
                    # There's an issue if the last character we wrote was at the very right end of the screen. In that case we need to
                    # emit a new line and move the cursor there. 
                    if curs_pos == cols
                        write(terminal,"\n")
                        cmove_col(terminal,1)
                        curs_row+=1
                        curs_pos=0
                        cur_row+=1
                    end
                else
                    cur_row += div(llength+indent-1,cols)
                    cmove_col(terminal,indent+1)
                    write(terminal,l)
                end

            end
            

        end

        seek(buf,buf_pos)

        # If we are at the end of the buffer, we need to put the cursor one past the 
        # last character we have written
        
        if curs_row == -1
            curs_pos = (indent+llength-1)%cols+1
            curs_row = cur_row
        end

        # Same issue as above. TODO: We should figure out 
        # how to refactor this to avoid duplcating functionality.
        if curs_pos == cols
            write(terminal,"\n")
            cmove_col(terminal,1)
            curs_row+=1
            curs_pos=0
            cur_row+=1
        end


        # Let's move the cursor to the right position
        # The line first
        n = cur_row-curs_row
        if n>0
            cmove_up(terminal,n)
        end

        #columns are 1 based
        cmove_col(terminal,curs_pos+1)

        flush(terminal)

        # Updated cur_row,curs_row
        return InputAreaState(cur_row,curs_row)
    end


    # Edit functionality

    char_move_left(s::PromptState) = char_move_left(s.input_buffer)
    function char_move_left(buf::IOBuffer)
        while position(buf)>0
            seek(buf,position(buf)-1)
            c = peek(buf)
            if ((c&0x80) == 0) || ((c&0xc0) == 0xc0)
                break
            end
        end
    end

    function edit_move_left(s::PromptState)
        if position(s.input_buffer)>0
            #move t=o the next UTF8 character to the left
            char_move_left(s.input_buffer)
            refresh_line(s)
        end
    end

    char_move_right(s::PromptState) = char_move_right(s.input_buffer)
    function char_move_right(buf::IOBuffer)
        while position(buf) != buf.size
            seek(buf,position(buf)+1)
            if position(buf)==buf.size
                break
            end
            c = peek(buf)
            if ((c&0x80) == 0) || ((c&0xc0) == 0xc0)
                break
            end
        end
    end

    const non_word_chars = " \t\n\"\\'`@\$><=:;|&{}()[].,+-*/?%^~"

    function char_move_word_right(s)
        while !eof(s.input_buffer) && !in(read(s.input_buffer,Char),non_word_chars)
        end
    end

    function char_move_word_left(s)
        while position(s.input_buffer) > 0
            char_move_left(s)
            c = peek(s.input_buffer)
            if c < 0x80 && in(char(c),non_word_chars)
                read(s.input_buffer,Uint8)
                break
            end
        end
    end

    function edit_move_right(s)
        if position(s.input_buffer)!=s.input_buffer.size
            #move to the next UTF8 character to the right
            char_move_right(s)
            refresh_line(s)
        end
    end

    function charlen(ch::Char)
        if ch < 0x80
            return 1
        elseif ch < 0x800
            return 2
        elseif ch < 0x10000
            return 3
        elseif ch < 0x110000
            return 4
        end
        error("Corrupt UTF8")
    end


    function edit_replace(s,from,to,str)
        room = length(str.data)-(to-from)
        ensureroom(s.input_buffer,s.input_buffer.size-to+room)
        ccall(:memmove, Void, (Ptr{Void},Ptr{Void},Int), pointer(s.input_buffer.data,to+room+1),pointer(s.input_buffer.data,to+1),s.input_buffer.size-to)
        s.input_buffer.size += room
        seek(s.input_buffer,from)
        write(s.input_buffer,str)
    end

    function edit_insert(s::PromptState,c)
        edit_insert(s.input_buffer,c)
        if c != '\n' && eof(s.input_buffer) && (position(s.input_buffer) + length(s.p.prompt)) < width(Readline.terminal(s)) 
            #Avoid full update
            write(Readline.terminal(s),c)
        else
            refresh_line(s)
        end
    end

    # TODO: Don't use memmove
    function edit_insert(buf::IOBuffer,c)
        if eof(buf)
            write(buf,c)
        else
            ensureroom(buf,buf.size-position(buf)+charlen(c))
            oldpos = position(buf)
            ccall(:memmove, Void, (Ptr{Void},Ptr{Void},Int), pointer(buf.data,position(buf)+1+charlen(c)), pointer(buf.data,position(buf)+1), 
                buf.size-position(buf))
            buf.size += charlen(c)
            write(buf,c)
        end
    end

    function edit_backspace(s::PromptState)
        if edit_backspace(s.input_buffer)
            refresh_line(s) 
        else
            beep(Readline.terminal(s))
        end

    end
    function edit_backspace(buf::IOBuffer)
        if position(buf) > 0 && buf.size>0
            oldpos = position(buf)
            char_move_left(buf)
            ccall(:memmove, Void, (Ptr{Void},Ptr{Void},Int), pointer(buf.data,position(buf)+1), pointer(buf.data,oldpos+1), 
                buf.size-oldpos) 
            buf.size -= oldpos-position(buf)
            return true
        else
            return false
        end
    end

    function edit_delete(s)
        if s.input_buffer.size>0 && position(s.input_buffer) < s.input_buffer.size
            oldpos = position(s.input_buffer)
            char_move_right(s)
            ccall(:memmove, Void, (Ptr{Void},Ptr{Void},Int), pointer(s.input_buffer.data,oldpos+1), pointer(s.input_buffer.data,position(s.input_buffer)+1), 
                s.input_buffer.size-position(s.input_buffer))
            s.input_buffer.size -= position(s.input_buffer)-oldpos
            seek(s.input_buffer,oldpos)
            refresh_line(s)
        else
            beep(Readline.terminal(s))
        end
    end

    function replace_line(s::PromptState,l::IOBuffer)
        s.input_buffer = l
    end

    function replace_line(s::PromptState,l)
        s.input_buffer.ptr = 1
        s.input_buffer.size = 0
        write(s.input_buffer,l)
    end

    history_prev(::EmptyHistoryProvider) = ("",false)
    history_next(::EmptyHistoryProvider) = ("",false)
    history_search(::EmptyHistoryProvider,args...) = false
    add_history(::EmptyHistoryProvider,s) = nothing
    add_history(s::PromptState) = add_history(mode(s).hist,s)


    function history_prev(s,hist) 
        (l,ok) = history_prev(mode(s).hist,s)
        if ok
            replace_line(s,l)
            refresh_line(s)
        else
            beep(Readline.terminal(s))
        end
    end
    function history_next(s,hist) 
        (l,ok) = history_next(mode(s).hist,s)
        if ok
            replace_line(s,l)
            refresh_line(s)
        else
            beep(Readline.terminal(s))
        end
    end

    refresh_line(s) = refreshMultiLine(s)

    default_completion_cb(::IOBuffer) = []
    default_enter_cb(::IOBuffer) = true

    write_prompt(terminal,s::PromptState) = write_prompt(terminal,s,s.p.prompt)
    function write_prompt(terminal,s::PromptState,prompt)
        @assert terminal == Readline.terminal(s)
        write(terminal,s.p.prompt_color)
        write(terminal,prompt)
        write(terminal,s.p.input_color)
    end
    write_prompt(terminal,s::ASCIIString) = write(terminal,s)

    function normalize_key(key)
        if isa(key,Char)
            return string(key)
        elseif isa(key,Integer)
            return string(char(key))
        elseif isa(key,String)
            if in('\0',key)
                error("Matching \\0 not currently supported.")
            end
            buf = IOBuffer()
            i = start(key)
            while !done(key,i)
                (c,i) = next(key,i)
                if c == '*'
                    write(buf,'\0')
                elseif c == '^'
                    (c,i) = next(key,i)
                    write(buf,uppercase(c)-64)
                elseif c == '\\'
                    (c,i) == next(key,i)
                    if c == 'C'
                        (c,i) == next(key,i)
                        @assert c == '-'
                        (c,i) == next(key,i)
                        write(buf,uppercase(c)-64)
                    elseif c == 'M'
                        (c,i) == next(key,i)
                        @assert c == '-'
                        (c,i) == next(key,i)
                        write(buf,'\e')
                        write(buf,c)
                    end
                else
                    write(buf,c)
                end
            end
            return takebuf_string(buf)
        end
    end

    # Turn an Dict{Any,Any} into a Dict{'Char',Any}
    # For now we use \0 to represent unknown chars so that they are sorted before everything else
    # If we ever actually want to mach \0 in input, this will have to be
    # reworked
    function normalize_keymap(keymap)
        ret = Dict{Char,Any}()
        for key in keys(keymap)
            newkey = normalize_key(key)
            current = ret
            i = start(newkey)
            while !done(newkey,i)
                (c,i) = next(newkey,i)
                if haskey(current,c)
                    if !isa(current[c],Dict)
                        println(ret)
                        error("Conflicting Definitions for keyseq "*escape_string(newkey)*" within one keymap")
                    end
                elseif done(newkey,i)
                    current[c] = keymap[key]
                    break
                else
                    current[c] = Dict{Char,Any}()
                end
                current = current[c]
            end
        end
        ret
    end

    keymap_gen_body(keymaps,body::Expr,level) = body
    keymap_gen_body(keymaps,body::Function,level) = keymap_gen_body(keymaps,:($(body)(s)))
    keymap_gen_body(keymaps,body::Char,level) = keymap_gen_body(keymaps,keymaps[body])
    keymap_gen_body(keymaps,body::Nothing,level) = nothing

    keymap_gen_body(a,b) = keymap_gen_body(a,b,1)
    function keymap_gen_body(dict,subdict::Dict,level)
        block = Expr(:block)
        bc = symbol("c"*string(level))
        push!(block.args,:($bc=read(Readline.terminal(s),Char)))

        if haskey(subdict,'\0')
            last_if = keymap_gen_body(dict,subdict['\0'],level+1)
        else 
            last_if = nothing
        end

        for c in keys(subdict)
            if c == '\0'
                continue
            end
            cblock = Expr(:if,:($bc==$c))
            push!(cblock.args,keymap_gen_body(dict,subdict[c],level+1))
            if isa(cblock,Expr)
                push!(cblock.args,last_if)
            end
            last_if = cblock
        end

        push!(block.args,last_if)
        return block
    end

    export @keymap

    # deep merge where target has higher precedence
    function keymap_merge!(target::Dict,source::Dict)
        for k in keys(source)
            if !haskey(target,k)
                target[k] = source[k]
            elseif isa(target[k],Dict)
                keymap_merge!(target[k],source[k])
            else
                # Ignore, target has higher precedence
            end
        end
    end

    fixup_keymaps!(d,l,s,sk) = nothing
    function fixup_keymaps!(dict::Dict, level, s, subkeymap)
        if level > 1
            for d in dict 
                fixup_keymaps!(d[2],level-1,s,subkeymap)
            end
        else
            if haskey(dict,s)
                if isa(dict[s],Dict) && isa(subkeymap,Dict)
                    keymap_merge!(dict[s],subkeymap)
                end
            else
                dict[s] = deepcopy(subkeymap)
            end
        end
    end

    function add_specialisations(dict,subdict,level)
        default_branch = subdict['\0']
        if isa(default_branch,Dict)
            for s in keys(default_branch)
                if s == '\0'
                    add_specialisations(dict,default_branch,level+1)
                end
                fixup_keymaps!(dict,level,s,default_branch[s])
            end
        end
    end

    fix_conflicts!(x) = fix_conflicts!(x,1)
    fix_conflicts!(others,level) = nothing
    function fix_conflicts!(dict::Dict,level)
        # needs to be done first for every branch
        if haskey(dict,'\0')
            add_specialisations(dict,dict,level)
        end
        for d in dict
            if d[1] == '\0'
                continue
            end
            fix_conflicts!(d[2],level+1)
        end
    end

    function keymap_prepare(keymaps)
        if isa(keymaps,Dict)
            keymaps = [keymaps]
        end
        push!(keymaps,{"*"=>:(error("Unrecognized input"))})
        @assert isa(keymaps,Array) && eltype(keymaps) <: Dict
        keymaps = map(normalize_keymap,keymaps)
        map(fix_conflicts!,keymaps)
        keymaps
    end

    function keymap_unify(keymaps)
        if length(keymaps) == 1
            return keymaps[1]
        else 
            ret = Dict{Char,Any}()
            for keymap in keymaps
                keymap_merge!(ret,keymap)
            end
            fix_conflicts!(ret)
            return ret
        end
    end

    macro keymap(func, keymaps)
        dict = keymap_unify(keymap_prepare(isa(keymaps,Expr)?eval(keymaps):keymaps))
        body = keymap_gen_body(dict,dict)
        esc(quote
            function $(func)(s,data)
                $body
                return :ok
            end
        end)
    end

    const escape_defaults = {
        # Ignore other escape sequences by default
        "\e*" => nothing,
        "\e[*" => nothing,
        # Also ignore extended escape sequences
        # TODO: Support tanges of characters
        "\e[1**" => nothing,
        "\e[2**" => nothing,
        "\e[3**" => nothing,
        "\e[4**" => nothing,
        "\e[5**" => nothing,
        "\e[6**" => nothing
    }

    function write_response_buffer(s::PromptState,data)
        offset = s.input_buffer.ptr
        ptr = data.respose_buffer.ptr
        seek(data.respose_buffer,0)
        write(s.input_buffer,readall(data.respose_buffer))
        s.input_buffer.ptr = offset+ptr-2
        data.respose_buffer.ptr = ptr
        refresh_line(s)
    end

    type SearchState
        terminal
        histprompt
        #rsearch (true) or ssearch (false)
        backward::Bool 
        query_buffer::IOBuffer
        respose_buffer::IOBuffer
        ias::InputAreaState
        #The prompt whose input will be replaced by the matched history
        parent
        SearchState(a,b,c,d,e) = new(a,b,c,d,e,InputAreaState(0,0)) 
    end    

    terminal(s::SearchState) = s.terminal

    function update_display_buffer(s::SearchState,data)
        history_search(data.histprompt.hp,data.query_buffer,data.respose_buffer,data.backward,false) || beep(Readline.terminal(s))
        refresh_line(s)
    end

    function history_next_result(s::MIState,data::SearchState)
        #truncate(data.query_buffer,s.input_buffer.size - data.respose_buffer.size)
        history_search(data.histprompt.hp,data.query_buffer,data.respose_buffer,data.backward,true) || beep(Readline.terminal(s))
        refresh_line(data)
    end

    function history_set_backward(s::SearchState,backward)
        s.backward = backward
    end

    function refreshMultiLine(s::SearchState)
        buf = IOBuffer()
        write(buf,pointer(s.query_buffer.data),s.query_buffer.ptr-1)
        write(buf,"': ")
        offset = buf.ptr
        ptr = s.respose_buffer.ptr
        seek(s.respose_buffer,0)
        write(buf,readall(s.respose_buffer))
        buf.ptr = offset+ptr-1
        s.respose_buffer.ptr = ptr
        refreshMultiLine(s.terminal,buf,s.ias,s.backward ? "(reverse-i-search)`" : "(i-search)`")
    end

    function reset_state(s::SearchState)
        if s.query_buffer.size != 0
            s.query_buffer.size = 0
            s.query_buffer.ptr = 1
        end
        if s.respose_buffer.size != 0
            s.respose_buffer.size = 0
            s.query_buffer.ptr = 1
        end
        reset_state(s.histprompt.hp)
    end

    type HistoryPrompt <: TextInterface
        hp::HistoryProvider
        keymap_func::Function
        HistoryPrompt(hp) = new(hp)
    end

    init_state(terminal,p::HistoryPrompt) = SearchState(terminal,p,true,IOBuffer(),IOBuffer())

    state(s::MIState,p) = s.mode_state[p]
    state(s::PromptState,p) = (@assert s.p == p; s)
    mode(s::MIState) = s.current_mode
    mode(s::PromptState) = s.p
    mode(s::SearchState) = @assert false

    function setup_search_keymap(hp) 
        p = HistoryPrompt(hp)
        pkeymap = {
            "^R" => :( Readline.history_set_backward(data,true); Readline.history_next_result(s,data) ),
            "^S" => :( Readline.history_set_backward(data,false); Readline.history_next_result(s,data) ),
            "\r" => (s)->begin
                parent = state(s,p).parent
                replace_line(state(s,parent),state(s,p).respose_buffer)
                transition(s,parent)
            end,
            "\t" => nothing, #TODO: Maybe allow tab completion in R-Search?

            # Backspace/^H
            '\b' => :(Readline.edit_backspace(data.query_buffer)?Readline.update_display_buffer(s,data):beep(Readline.terminal(s))),
            127 => '\b',
            "^C" => s->transition(s,state(s,p).parent),
            "^D" => s->transition(s,state(s,p).parent),
            "*" => :(Readline.edit_insert(data.query_buffer,c1);Readline.update_display_buffer(s,data))
        }
        @eval @Readline.keymap keymap_func $([pkeymap, escape_defaults])
        p.keymap_func = keymap_func
        keymap = {
            "^R" => s->( state(s,p).parent = mode(s); state(s,p).backward = true; transition(s,p) ),
            "^S" => s->( state(s,p).parent = mode(s); state(s,p).backward = false; transition(s,p) ),
        }
        (p,keymap)
    end

    keymap(state,p::HistoryPrompt) = p.keymap_func
    keymap_data(state,::HistoryPrompt) = state

    Base.isempty(s::PromptState) = s.input_buffer.size == 0

    on_enter(s::PromptState) = s.p.on_enter(s)

    const default_keymap =
    {   
        # Tab
        '\t' => :(Readline.completeLine(s); Readline.refresh_line(s)),
        # Enter
        '\r' => quote
            if Readline.on_enter(s)
                println(Readline.terminal(s))
                Readline.add_history(s)
                return :done
            else
                Readline.edit_insert(s,'\n')
            end
        end,
        # Backspace/^H
        '\b' => edit_backspace,
        127 => '\b',
        # ^D
        4 => quote 
            if Readline.buffer(s).size > 0
                Readline.edit_delete(s)
            else
                println(Readline.terminal(s))
                return :abort
            end
        end,
        # ^B
        2 => edit_move_left,
        # ^F
        6 => edit_move_right,
        # Meta Enter
        "\e\r" => :(Readline.edit_insert(s,'\n')),
        # Simply insert it into the buffer by default
        "*" => :( Readline.edit_insert(s,c1) ),
        # ^U
        21 => :( truncate(Readline.buffer(s),0); Readline.refresh_line(s) ),
        # ^K
        11 => :( truncate(Readline.buffer(s),position(Readline.buffer(s))) ),
        # ^A    
        1 => :( seek(Readline.buffer(s),0); Readline.refresh_line(s) ),
        # ^E
        5 => :( seekend(Readline.buffer(s));Readline.refresh_line(s) ),
        # ^L
        12 => :( Terminals.clear(Readline.terminal(s)); Readline.refresh_line(s) ),
        # ^W (#edit_delte_prev_word(s))
        23 => :( error("Unimplemented") ),
        # ^C
        "^C" => :( print(Readline.terminal(s), "^C\n\n"); transition(s,:reset); Readline.refresh_line(s) ),
        # Right Arrow
        "\e[C" => edit_move_right,
        # Left Arrow
        "\e[D" => edit_move_left,
    }

    function history_keymap(hist) 
        return {
            # ^P
            16 => :( Readline.history_prev(s,$hist) ),
            # ^N
            14 => :( Readline.history_next(s,$hist) ),
            # Up Arrow
            "\e[A" => :( Readline.history_prev(s,$hist) ),
            # Down Arrow
            "\e[B" => :( Readline.history_next(s,$hist) )
        }
    end

    function deactivate(p::Union(Prompt,HistoryPrompt),s::Union(SearchState,PromptState))
        clear_input_area(s)
        s
    end

    function activate(p::Union(Prompt,HistoryPrompt),s::Union(SearchState,PromptState))
        s.ias = InputAreaState(0,0)
        refresh_line(s)
    end

    function activate(p::Union(Prompt,HistoryPrompt),s::MIState)
        @assert p == s.current_mode
        activate(p,s.mode_state[s.current_mode])
    end
    activate(m::ModalInterface,s::MIState) = activate(s.current_mode,s)

    function transition(s::MIState,mode)
        if mode == :abort
            s.aborted = true
            return
        end
        if mode == :reset 
            reset_state(s)
            return
        end
        s.mode_state[s.current_mode] = deactivate(s.current_mode,s.mode_state[s.current_mode])
        s.current_mode = mode
        activate(mode,s.mode_state[mode])
    end

    function reset_state(s::PromptState)
        if s.input_buffer.size != 0
            s.input_buffer.size = 0
            s.input_buffer.ptr = 1
        end
    end

    function reset_state(s::MIState)
        for (mode,state) in s.mode_state
            reset_state(state)
        end
    end

    @Readline.keymap default_keymap_func [Readline.default_keymap,Readline.escape_defaults]

    function Prompt(prompt;
        first_prompt = prompt,
        prompt_color="",
        keymap_func = default_keymap_func,
        keymap_func_data = nothing,
        input_color="",
        complete=EmptyCompletionProvider(),
        on_enter=default_enter_cb,on_done=()->nothing,hist=EmptyHistoryProvider())
        Prompt(prompt,first_prompt,prompt_color,keymap_func,keymap_func_data,input_color,complete,on_enter,on_done,hist)
    end

    function run_interface(::Prompt)

    end

    init_state(terminal,prompt::Prompt) = PromptState(terminal,prompt,IOBuffer(),InputAreaState(1,1),length(prompt.prompt))

    function init_state(terminal,m::ModalInterface)
        s = MIState(m,m.modes[1],false,Dict{Any,Any}())
        for mode in m.modes
            s.mode_state[mode] = init_state(terminal,mode)
        end
        s
    end

    function run_interface(terminal,m::ModalInterface)
        s = init_state(terminal,m)
        while !s.aborted
            p = s.current_mode
            buf,ok = prompt!(terminal,m,s)
            s.mode_state[s.current_mode].p.on_done(s,buf,ok)
        end
    end

    buffer(s::PromptState) = s.input_buffer
    buffer(s::SearchState) = s.query_buffer

    keymap(s::PromptState,prompt::Prompt) = prompt.keymap_func
    keymap_data(s::PromptState,prompt::Prompt) = prompt.keymap_func_data
    keymap(ms::MIState,m::ModalInterface) = keymap(ms.mode_state[ms.current_mode],ms.current_mode)
    keymap_data(ms::MIState,m::ModalInterface) = keymap_data(ms.mode_state[ms.current_mode],ms.current_mode)

    function prompt!(terminal,prompt,s=init_state(terminal,prompt))
        raw!(terminal,true)
        try
            activate(prompt,s)
            while true
                state = keymap(s,prompt)(s,keymap_data(s,prompt))
                if state == :abort
                    return (buffer(s),false)
                elseif state == :done
                    return (buffer(s),true)
                else
                    @assert state == :ok
                end
            end
        finally
            raw!(terminal,false)
        end
    end
end