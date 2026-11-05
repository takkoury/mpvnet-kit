local entries, parsed = {}, {}
package.loaded['mp'] = {}
package.loaded['mp.utils'] = {parse_json=function(line)
    parsed[#parsed+1]=line
    return entries[line:gsub('\r$', '')]
end}
package.loaded['mp.options'] = {read_options=function(opts, name)
    assert(name=='select' and opts.hide_history_duplicates==true)
    assert(opts.history_date_format=='%Y-%m-%d %H:%M:%S')
    opts.history_date_format='!%Y/%m/%d'
    opts.hide_history_duplicates=false
end}

-- DATA MODULE IS INSERTED HERE

local function eq(actual, expected)
    assert(actual==expected,'expected '..tostring(expected)..', got '..tostring(actual))
end

function reverse_file_order_and_exact_path_deduplication()
    local t1,t2,t3=1735689600,1767225600,1798761600
    local a,b,c,d='C:\\Alpha\\片段.mkv','C:/Beta/片段.mkv','C:\\alpha\\片段.mkv',
        'https://user:pass@example.invalid/series/episode.mp4?token=fixture#test'
    entries.old={path=a,time=t3,title='Old metadata'}
    entries.second={path=b,time=t2}
    entries.third={path=c,time=t2,title=c}
    entries.network={path=d,time=t3}
    entries.latest={path=a,time=t1}
    local content='\239\187\191old\r\nsecond\nthird\nnetwork\nlatest'
    local opts=Data.options()
    local rows, notice=Data.parse(content,opts)
    eq(notice,'');eq(#rows,5);eq(rows[5].title,'Old metadata');eq(rows[5].parent_text,'')
    opts.hide_history_duplicates=true
    rows=Data.parse(content,opts)
    eq(#rows,4)
    eq(rows[1].history_path,a);eq(rows[1].title,'片段.mkv');eq(rows[1].date_text,'2025/01/01');eq(rows[1].parent_text,'Alpha')
    eq(rows[2].history_path,d);eq(rows[2].title,'episode.mp4');eq(rows[2].parent_text,'')
    eq(rows[3].history_path,c);eq(rows[3].title,'片段.mkv');eq(rows[3].parent_text,'alpha')
    eq(rows[4].history_path,b);eq(rows[4].parent_text,'Beta')
    eq(entries.latest.title,nil);eq(entries.latest.time,t1)
end

function invalid_lines_never_become_loadable_truncated_paths()
    local nul_escape='{"path":"D:/test\\u0000wrong","time":1735689600}'
    local literal_escape='{"path":"D:/test\\\\u0000literal","time":1735689600}'
    -- The native JSON C-string conversion could return the truncated path.
    entries[nul_escape]={path='D:/test',time=1735689600}
    entries[literal_escape]={path='D:/test\\u0000literal',time=1735689600,title='标题\n下一行'}
    entries.nul={path='D:/x\0wrong',time=1735689600}
    entries.empty={path='',time=1735689600}
    entries.invalidtime={path='D:/x',time=1e30}
    entries.stringtime={path='D:/x',time='1735689600'}
    entries.notnumber={path='D:/x',time=0/0}
    local input=table.concat({nul_escape,literal_escape,'nul','empty','invalidtime','stringtime','notnumber','{broken',''},'\n')
    local rows,notice=Data.parse(input,{history_date_format='!%Y/%m/%d'})
    eq(#rows,1);eq(rows[1].title,'标题 下一行');eq(rows[1].history_path,entries[literal_escape].path)
    eq(notice,'已跳过 7 条无效记录。');eq(parsed[1],literal_escape)
end

function unsafe_date_options_use_default_and_missing_metadata_uses_basename()
    entries.valid={path='relative movie.mkv',time=1735689600,title={}}
    local expected=os.date('%Y-%m-%d %H:%M:%S',1735689600)
    for _,format in ipairs({'%Q','%P','%','!*t','*t','%Y\0%Q','  '}) do
        local rows,notice=Data.parse('valid',{history_date_format=format})
        eq(#rows,1);eq(rows[1].date_text,expected);eq(rows[1].title,'relative movie.mkv')
        eq(notice,'时间格式无效，已使用默认格式。')
    end
end
