local properties = {}
package.loaded['mp'] = {get_property=function(name) return properties[name] end}
package.loaded['mp.utils'] = {}

-- DATA MODULE IS INSERTED HERE

local function eq(actual, expected)
    assert(actual==expected, 'expected '..tostring(expected)..', got '..tostring(actual))
end

local function parse(files, skipped)
    return Data.parse({files=files, skipped=skipped or {}})
end

function sorted_rows_keep_exact_path_and_saved_bytes()
    local local_path = 'D:\\合成\\备份 [一]\\同名.mkv'
    local url = 'https://host.invalid/网络/同名.mkv?test=one#chapter'
    local crlf = '\239\187\191# '..local_path..'\r\nstart=8.000000\r\n'
    local records, status = parse({
        {name='B', content=crlf, mtime=1735732800.9},
        {name='R', content='# redirect entry\r\n', mtime=1735732900},
        {name='C', content='# '..url, mtime=1735732801.1},
        {name='A', content='# D:/其他/不同名.mkv\noption=untouched', mtime=1735732800.9},
    })
    eq(#records, 3);eq(status.notice,'');eq(status.no_path,false);eq(status.unreadable,false)
    eq(records[1].row.history_path,url);eq(records[1].row.title,'同名.mkv')
    eq(records[1].row.parent_text,'网络');eq(records[1].row.current,nil)
    eq(records[2].name,'A');eq(records[2].row.parent_text,'')
    eq(records[3].row.history_path,local_path);eq(records[3].row.parent_text,'备份 [一]')
    eq(records[3].row.date_text,'保存于 '..os.date('%Y-%m-%d',1735732800));eq(records[3].content,crlf)
end

function invalid_entries_remain_distinct_from_redirect_and_empty()
    local records, status = parse({
        {name='R', content='# redirect entry', mtime=1},
        {name='A', content='', mtime=1},
        {name='B', content='start=8\n# D:/not-first-line.mkv', mtime=1},
        {name='C', content='#   \r\n', mtime=1},
        {name='D', content='# D:/one.mkv\rD:/truncated.mkv', mtime=1},
        {name='E', content='# D:/one.mkv\0D:/truncated.mkv', mtime=1},
        {name='F', content='# D:/one.mkv', mtime=math.huge},
        {name='G', content='# D:/one.mkv', mtime=0/0},
        {name='H', content=string.rep('a',64*1024+1), mtime=1},
        {name='I', content='# D:/good.mkv\n', mtime=1},
    }, {io=2, encoding=1, too_large=1})
    eq(#records,1);eq(records[1].name,'I');eq(status.no_path,true);eq(status.unreadable,true)
    assert(status.notice:find('4 条保存记录无法读取',1,true))
    assert(status.notice:find('2 条记录含无效 UTF-8',1,true))
    assert(status.notice:find('2 条记录超出读取限制',1,true))
    assert(status.notice:find('4 条缺少媒体路径',1,true))
    records,status=parse({{name='R',content='# redirect entry',mtime=1}})
    eq(#records,0);eq(status.no_path,false);eq(status.unreadable,false)
end

function snapshot_recheck_uses_literal_leaf_and_extra_byte()
    properties['working-directory']='D:\\合成'
    properties['current-watch-later-dir']='[相对] watch_later'
    local directory=Data.source()
    eq(directory,'D:\\合成/[相对] watch_later')
    properties['current-watch-later-dir']='\\synthetic'
    eq(Data.source(),'D:\\synthetic')
    properties['current-watch-later-dir']='D:synthetic'
    eq(Data.source(),'D:\\合成/synthetic')
    properties['current-watch-later-dir']='D:'
    eq(Data.source(),'D:\\合成')
    properties['current-watch-later-dir']='C:synthetic'
    eq(Data.source(),nil)
    properties['current-watch-later-dir']='\\\\host\\share\\records'
    eq(Data.source(),'\\\\host\\share\\records')
    properties['current-watch-later-dir']='contains\0null'
    eq(Data.source(),nil)
    local content, expected = '# D:/one.mkv\nstart=8\n', '# D:/one.mkv\nstart=8\n'
    local read_count=0
    io.open=function(path, mode)
        read_count=read_count+1
        eq(path,directory..'/合成 [A]');eq(mode,'rb')
        return {read=function(_, size) eq(size,#expected+1);return content:sub(1,size) end,
            close=function() end}
    end
    assert(Data.matches(directory,{name='合成 [A]',content=expected}))
    content=content..'X'
    eq(Data.matches(directory,{name='合成 [A]',content=expected}),false)
    for _, leaf in ipairs({'..', '..\\escape', '../escape', 'C:escape', 'CON.txt', 'a.', 'NUL', 'a '}) do
        eq(Data.matches(directory,{name=leaf,content=expected}),false)
    end
    eq(read_count,2)
end
