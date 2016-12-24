if !exists('g:vlime_ui')
    let g:vlime_ui = vlime#ui#New()
endif

if !exists('g:vlime_connections')
    let g:vlime_connections = {}
endif

if !exists('g:vlime_next_conn_id')
    let g:vlime_next_conn_id = 1
endif

" VlimeNewConnection([name])
function! VlimeNewConnection(...)
    if a:0 > 0
        let conn_name = a:1
    else
        let conn_name = 'Vlime Connection ' . g:vlime_next_conn_id
    endif
    let conn = vlime#New(
                \ {
                    \ 'id': g:vlime_next_conn_id,
                    \ 'name': conn_name
                \ },
                \ g:vlime_ui)
    let g:vlime_connections[g:vlime_next_conn_id] = conn
    let g:vlime_next_conn_id += 1
    return conn
endfunction

function! VlimeCloseConnection(conn)
    let conn_id = s:NormalizeConnectionID(a:conn)
    let r_conn = remove(g:vlime_connections, conn_id)
    call r_conn.Close()
endfunction

function! VlimeRenameConnection(conn, new_name)
    let conn_id = s:NormalizeConnectionID(a:conn)
    let r_conn = g:vlime_connections[conn_id]
    let r_conn.cb_data.name = a:new_name
endfunction

" VlimeConnectREPL(host, port[, name])
function! VlimeConnectREPL(host, port, ...)
    if a:0 > 0
        let conn = VlimeNewConnection(a:1)
    else
        let conn = VlimeNewConnection()
    endif
    call conn.Connect(a:host, a:port)
    call conn.ConnectionInfo(v:true, function('s:OnConnectionInfoComplete'))
endfunction

function! VlimeSelectConnection(quiet)
    if len(g:vlime_connections) == 0
        if !a:quiet
            call s:ErrMsg('Vlime not connected.')
        endif
        return v:null
    else
        let conn_names = []
        for k in sort(keys(g:vlime_connections), 'n')
            let conn = g:vlime_connections[k]
            let chan_info = ch_info(conn.channel)
            call add(conn_names, k . '. ' . conn.cb_data.name .
                        \ ' (' . chan_info['hostname'] . ':' . chan_info['port'] . ')')
        endfor

        echohl Question
        echom 'Which connection to use?'
        echohl None
        let conn_nr = inputlist(conn_names)
        if conn_nr == 0
            if !a:quiet
                call s:ErrMsg('Canceled.')
            endif
            return v:null
        else
            let conn = get(g:vlime_connections, conn_nr, v:null)
            if type(conn) == v:t_none
                if !a:quiet
                    call s:ErrMsg('Invalid connection ID: ' . conn_nr)
                endif
                return v:null
            else
                return conn
            endif
        endif
    endif
endfunction

" VlimeGetConnection([quiet])
function! VlimeGetConnection(...) abort
    let quiet = vlime#GetNthVarArg(a:000, 0, v:false)

    if !exists('b:vlime_conn') ||
                \ (type(b:vlime_conn) != v:t_none &&
                    \ !b:vlime_conn.IsConnected()) ||
                \ (type(b:vlime_conn) == v:t_none && !quiet)
        if len(g:vlime_connections) == 1 && !exists('b:vlime_conn')
            let b:vlime_conn = g:vlime_connections[keys(g:vlime_connections)[0]]
        else
            let conn = VlimeSelectConnection(quiet)
            if type(conn) == v:t_none
                if quiet
                    " No connection found. Set this variable to v:null to
                    " make it 'quiet'
                    let b:vlime_conn = conn
                else
                    return conn
                endif
            else
                let b:vlime_conn = conn
            endif
        endif
    endif
    return b:vlime_conn
endfunction

function! VlimeSendCurExprToREPL()
    let expr = vlime#ui#CurExpr()
    if len(expr) > 0
        let conn = VlimeGetConnection()
        if type(conn) == v:t_none
            return
        endif

        call conn.ui.OnWriteString(conn, "--\n", {'name': 'REPL-SEP', 'package': 'KEYWORD'})
        call conn.WithThread({'name': 'REPL-THREAD', 'package': 'KEYWORD'},
                    \ function(conn.ListenerEval, [expr]))
    endif
endfunction

function! VlimeSendCurAtomToREPL()
    let atom = vlime#ui#CurAtom()
    if len(atom) > 0
        let conn = VlimeGetConnection()
        if type(conn) == v:t_none
            return
        endif

        call conn.ui.OnWriteString(conn, "--\n", {'name': 'REPL-SEP', 'package': 'KEYWORD'})
        call conn.WithThread({'name': 'REPL-THREAD', 'package': 'KEYWORD'},
                    \ function(conn.ListenerEval, [atom]))
    endif
endfunction

function! VlimeSendCurThingToREPL()
    let thing = vlime#ui#CurExpr()
    if len(thing) <= 0
        let thing = vlime#ui#CurAtom()
    endif
    if len(thing) > 0
        let conn = VlimeGetConnection()
        if type(conn) == v:t_none
            return
        endif

        call conn.ui.OnWriteString(conn, "--\n", {'name': 'REPL-SEP', 'package': 'KEYWORD'})
        call conn.WithThread({'name': 'REPL-THREAD', 'package': 'KEYWORD'},
                    \ function(conn.ListenerEval, [thing]))
    endif
endfunction

function! VlimeSwankRequire(contribs)
    let conn = VlimeGetConnection()
    if type(conn) == v:t_none
        return
    endif
    call conn.SwankRequire(a:contribs, function('s:OnSwankRequireComplete', [v:false]))
endfunction

function! VlimeCurOperatorArgList()
    let op = vlime#ui#CurOperator()
    let conn = VlimeGetConnection(v:true)
    if type(conn) == v:t_none
        return
    endif
    call conn.OperatorArgList(op, function('s:OnOperatorArgListComplete', [op]))
endfunction

function! VlimeDescribeCurSymbol()
    let sym = vlime#ui#CurOperator()
    let conn = VlimeGetConnection()
    if type(conn) == v:t_none
        return
    endif
    call conn.DescribeSymbol(sym, function('s:OnDescribeSymbolComplete'))
endfunction

function! VlimeCompleteFunc(findstart, base)
    let start_col = s:CompleteFindStart()
    if a:findstart
        return start_col
    endif

    let conn = VlimeGetConnection()
    if type(conn) == v:t_none
        return -1
    endif

    if s:ConnHasContrib(conn, 'SWANK-FUZZY')
        call conn.FuzzyCompletions(a:base,
                    \ function('s:OnFuzzyCompletionsComplete', [start_col + 1]))
    else
        call conn.SimpleCompletions(a:base,
                    \ function('s:OnSimpleCompletionsComplete', [start_col + 1]))
    endif
    " Actual completions are found in s:OnFuzzyCompletionsComplete(...)
    " XXX: The refresh option doesn't work, why?
    return {'words': [], 'refresh': 'always'}
endfunction

function! VlimeComplete()
    let conn = VlimeGetConnection()
    if type(conn) == v:t_none
        return
    endif

    let start_col = s:CompleteFindStart()
    let end_col = col('.') - 1
    let line = getline('.')
    if end_col <= start_col
        let base = ''
    else
        let base = line[start_col:end_col-1]
    endif

    if s:ConnHasContrib(conn, 'SWANK-FUZZY')
        call conn.FuzzyCompletions(base,
                    \ function('s:OnFuzzyCompletionsComplete', [start_col + 1]))
    else
        call conn.SimpleCompletions(base,
                    \ function('s:OnSimpleCompletionsComplete', [start_col + 1]))
    endif
endfunction

function! VlimeKey(key)
    if tolower(a:key) == 'space'
        call VlimeCurOperatorArgList()
    elseif tolower(a:key) == 'cr'
        call VlimeCurOperatorArgList()
    elseif tolower(a:key) == 'tab'
        if pumvisible()
            return "\<c-n>"
        else
            return "\<c-x>\<c-o>"
        endif
    else
        throw 'VlimeKey: Unknown key: ' . a:key
    endif
    return ''
endfunction

function! VlimeSetup()
    if exists('g:vlime_address')
        let [host, port] = g:vlime_address
    else
        let [host, port] = ['127.0.0.1', 7002]
    endif

    setlocal omnifunc=VlimeCompleteFunc
    setlocal filetype=lisp

    inoremap <buffer> <space> <space><c-r>=VlimeKey('space')<cr>
    inoremap <buffer> <cr> <cr><c-r>=VlimeKey("cr")<cr>
    inoremap <buffer> <tab> <c-r>=VlimeKey("tab")<cr>
    execute 'nnoremap <buffer> <LocalLeader>c :call VlimeConnectREPL(' . string(host) . ', ' . port . ')<cr>'
    nnoremap <buffer> <LocalLeader>S :call VlimeSelectConnection(v:false)<cr>
    nnoremap <buffer> <LocalLeader>d :call VlimeCloseConnection(b:vlime_conn)<cr>
    nnoremap <buffer> <LocalLeader>i :call VlimeInteractionMode()<cr>
    nnoremap <buffer> <LocalLeader>s :call VlimeDescribeCurSymbol()<cr>
endfunction

function! VlimeInteractionMode()
    if getbufvar(bufnr('%'), 'vlime_interaction_mode', v:false)
        let b:vlime_interaction_mode = v:false
        nnoremap <cr> <cr>
    else
        let b:vlime_interaction_mode = v:true
        nnoremap <cr> :call VlimeSendCurThingToREPL()<cr>
    endif
endfunction

function! s:NormalizeConnectionID(id)
    if type(a:id) == v:t_dict
        return a:id.cb_data.id
    else
        return a:id
    endif
endfunction

function! s:CompleteFindStart()
    let col = col('.') - 1
    let line = getline('.')
    while col > 0 && match(line[col-1], '\_s\|[()#;"'']') < 0
        let col -= 1
    endwhile
    return col
endfunction

function! s:ConnHasContrib(conn, contrib)
    return has_key(a:conn.cb_data, 'contribs') &&
                \ index(a:conn.cb_data['contribs'], a:contrib) >= 0
endfunction

function! s:OnCreateREPLComplete(conn, result)
    echom '-- OnCreateREPLComplete -------------------------'
    echom a:conn.cb_data.name . ' established.'
endfunction

function! s:OnSwankRequireComplete(create_repl, conn, result)
    echom '-- OnSwankRequireComplete -------------------------'
    let a:conn.cb_data['contribs'] = a:result
    if a:create_repl && s:ConnHasContrib(a:conn, 'SWANK-REPL')
        call a:conn.CreateREPL(v:null, function('s:OnCreateREPLComplete'))
    endif
endfunction

function! s:OnConnectionInfoComplete(conn, result)
    echom '-- OnConnectionInfoComplete -------------------------'
    let a:conn.cb_data['version'] = a:result['VERSION']
    let a:conn.cb_data['pid'] = a:result['PID']
    call a:conn.SwankRequire(['SWANK-REPL'],
                \ function('s:OnSwankRequireComplete', [v:true]))
endfunction

function! s:OnFuzzyCompletionsComplete(col, conn, result)
    let comps = a:result[0]
    if type(comps) == v:t_none
        let comps = []
    endif
    let r_comps = []
    for c in comps
        let cobj = {'word': c[0],'menu': c[3]}
        call add(r_comps, cobj)
    endfor
    call complete(a:col, r_comps)
endfunction

function! s:OnSimpleCompletionsComplete(col, conn, result)
    echom string(a:result)
    let comps = a:result[0]
    if type(comps) == v:t_none
        let comps = []
    endif
    call complete(a:col, comps)
endfunction

function! s:OnOperatorArgListComplete(sym, conn, result)
    if type(a:result) == v:t_none
        return
    endif
    let old_pos = getcurpos()
    try
        call vlime#ui#ShowPreview(a:result . "\n\n", v:false, 2)
    finally
        call setpos('.', old_pos)
    endtry
endfunction

function! s:OnDescribeSymbolComplete(conn, result)
    let old_pos = getcurpos()
    try
        call vlime#ui#ShowPreview(a:result, v:false, 12)
    finally
        call setpos('.', old_pos)
    endtry
endfunction

function! s:ErrMsg(msg)
    echohl ErrorMsg
    echom a:msg
    echohl None
endfunction
