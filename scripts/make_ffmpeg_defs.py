"""Generate .def files for ARM64 FFmpeg DLLs shipped inside the PyAV 19.0.1 wheel."""
from pathlib import Path
import struct
import sys


def u16(d, o):
    return struct.unpack_from('<H', d, o)[0]


def u32(d, o):
    return struct.unpack_from('<I', d, o)[0]


def rva_to_offset(d, sections, rva):
    for va, vsize, raw_off, raw_size in sections:
        if va <= rva < va + max(vsize, raw_size):
            return raw_off + (rva - va)
    raise ValueError(f'RVA {rva:#x} not in any section')


def exports(path):
    d = path.read_bytes()
    pe = u32(d, 0x3c)
    assert d[pe:pe + 4] == b'PE\0\0', path
    coff = pe + 4
    nsec = u16(d, coff + 2)
    opt_size = u16(d, coff + 16)
    opt = coff + 20
    magic = u16(d, opt)
    assert magic == 0x20b, f'{path}: not PE32+'
    dd = opt + 112
    exp_rva = u32(d, dd)
    exp_size = u32(d, dd + 4)
    sec_off = opt + opt_size
    sections = []
    for i in range(nsec):
        s = sec_off + i * 40
        sections.append((u32(d, s + 12), u32(d, s + 8), u32(d, s + 20), u32(d, s + 16)))
    base = rva_to_offset(d, sections, exp_rva)
    name_rva = u32(d, base + 12)
    nfuncs = u32(d, base + 20)
    nnames = u32(d, base + 24)
    afunc = u32(d, base + 28)
    aname = u32(d, base + 32)
    aord = u32(d, base + 36)
    dll_name = d[rva_to_offset(d, sections, name_rva):].split(b'\0', 1)[0].decode()
    result = {}
    for i in range(nnames):
        nrva = u32(d, rva_to_offset(d, sections, aname) + i * 4)
        name = d[rva_to_offset(d, sections, nrva):].split(b'\0', 1)[0].decode('ascii')
        ordinal = u16(d, rva_to_offset(d, sections, aord) + i * 2)
        frva = u32(d, rva_to_offset(d, sections, afunc) + ordinal * 4)
        if frva == 0:
            continue
        result[name] = ordinal + 1  # OrdinalBase is 1 in these DLLs
    return dll_name, result


def main():
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    wanted = {
        'avcodec': 'avcodec_alloc_context3 avcodec_find_decoder avcodec_free_context avcodec_open2 '
                   'avcodec_parameters_to_context avcodec_receive_frame avcodec_send_packet '
                   'av_packet_alloc av_packet_free av_packet_unref',
        'avformat': 'avformat_alloc_context avformat_close_input avformat_find_stream_info '
                    'avformat_open_input avformat_seek_file avio_alloc_context avio_context_free '
                    'av_read_frame av_seek_frame',
        'avutil': 'av_frame_alloc av_frame_copy_props av_frame_free av_frame_get_buffer av_frame_unref '
                  'av_free av_freep av_log_set_level av_malloc',
        'swscale': 'sws_alloc_context sws_freeContext sws_scale_frame',
    }
    dlls = {}
    for p in list(src.glob('av*-*.dll')) + list(src.glob('swscale-*.dll')):
        stem = p.name.split('-', 1)[0]
        dlls.setdefault(stem, p)
    for lib, names in wanted.items():
        p = dlls[lib]
        dll_name, exps = exports(p)
        missing = [n for n in names.split() if n not in exps]
        if missing:
            raise SystemExit(f'{p.name}: missing exports {missing}')
        lines = [f'LIBRARY "{Path(dll_name).stem}"', 'EXPORTS']
        for n in sorted(names.split()):
            lines.append(f'    {n} @{exps[n]}')
        target = out / f'{lib}.def'
        target.write_text('\n'.join(lines) + '\n', encoding='ascii')
        print(f'{lib}: {p.name} -> {target.name} ({len(names.split())} exports)')


if __name__ == '__main__':
    main()
