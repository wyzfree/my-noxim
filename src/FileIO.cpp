/*
 * FileIO - Multi-process cross-chip communication via files
 */

#include "FileIO.h"
#include <cstdio>
#include <algorithm>
#include <fcntl.h>
#include <unistd.h>
#include <filesystem>

using namespace std;

// ============================================================
// Constructor
// ============================================================
FileIO::FileIO(sc_module_name name, NoC* noc,
               const string& in_fifo_path,
               const string& out_fifo_path,
               const string& cross_out_path)
    : sc_module(name), noc_(noc), in_path_(in_fifo_path), out_path_(out_fifo_path),
      inbox_mode_(false), inbox_dir_(""), cross_out_path_(cross_out_path)
{
    chip_id     = GlobalParams::chip_id;
    total_ports = 2 * (GlobalParams::mesh_dim_x + GlobalParams::mesh_dim_y);

    // Allocate port arrays
    flit_in_ports    = new sc_out<Flit>*             [total_ports];
    req_in_ports     = new sc_out<bool>*             [total_ports];
    ack_in_ports     = new sc_in<bool>*              [total_ports];
    buf_status_ports = new sc_in<TBufferFullStatus>* [total_ports];
    flit_out_ports   = new sc_in<Flit>*              [total_ports];
    req_out_ports    = new sc_in<bool>*              [total_ports];
    ack_out_ports    = new sc_out<bool>*             [total_ports];

    for (int i = 0; i < total_ports; i++) {
        char buf[64];
        sprintf(buf, "flit_in_%d",    i); flit_in_ports   [i] = new sc_out<Flit>(buf);
        sprintf(buf, "req_in_%d",     i); req_in_ports    [i] = new sc_out<bool>(buf);
        sprintf(buf, "ack_in_%d",     i); ack_in_ports    [i] = new sc_in<bool>(buf);
        sprintf(buf, "buf_status_%d", i); buf_status_ports[i] = new sc_in<TBufferFullStatus>(buf);
        sprintf(buf, "flit_out_%d",   i); flit_out_ports  [i] = new sc_in<Flit>(buf);
        sprintf(buf, "req_out_%d",    i); req_out_ports   [i] = new sc_in<bool>(buf);
        sprintf(buf, "ack_out_%d",    i); ack_out_ports   [i] = new sc_out<bool>(buf);
    }

    level_in .assign(total_ports, false);
    level_out.assign(total_ports, false);
    inQueue  .assign(total_ports, queue<Flit>());
    stats_queue_hwm.assign(total_ports, 0);
    stats_rx_from_file = 0;
    stats_tx_to_file   = 0;
    stats_records_parsed = 0;

    // Output target mode:
    // 1) ring mode (legacy): out_path_ is a file
    // 2) inbox mode: out_path_ is a directory, writeRecord routes by dst_chip
    out_fd_ = -1;
    try {
        if (std::filesystem::is_directory(out_path_)) {
            inbox_mode_ = true;
            inbox_dir_ = out_path_;
            cout << "[FileIO chip " << chip_id << "] inbox mode enabled, dir=" << inbox_dir_ << endl;
        }
    } catch (...) {
        // keep legacy mode if filesystem probing fails
    }

    if (!inbox_mode_) {
        // Open output file (truncate on start).
        // Also open a raw fd for cross-process flock() locking.
        out_fd_ = open(out_path_.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (out_fd_ < 0)
            cerr << "[FileIO] WARNING: cannot open out_fifo (fd): " << out_path_ << endl;
        out_file_.open(out_path_, ios::out | ios::trunc);
        if (!out_file_.is_open())
            cerr << "[FileIO] WARNING: cannot open out_fifo (stream): " << out_path_ << endl;
    }

    // Try to open input file (may not exist yet, fileReaderThread will retry)
    in_offset_ = 0;
    in_partial_line_.clear();

    connectAll(noc);

    SC_METHOD(process);
    sensitive << reset;
    sensitive << clock.pos();

    SC_THREAD(fileReaderThread);
    sensitive << clock.pos();

    if (!cross_out_path_.empty()) {
        SC_THREAD(crossOutThread);
        sensitive << clock.pos();
    }
}

// ============================================================
// process: 每个时钟沿调用
// ============================================================
void FileIO::process()
{
    txProcess();
    rxProcess();
}

// ============================================================
// txProcess: 从 inQueue 向 NoC 边界注入 flit（ABP 握手）
// ============================================================
void FileIO::txProcess()
{
    if (reset.read()) {
        for (int p = 0; p < total_ports; p++) {
            req_in_ports[p]->write(false);
            level_in[p] = false;
        }
        return;
    }

    for (int p = 0; p < total_ports; p++) {
        int qsz = (int)inQueue[p].size();
        if (qsz > stats_queue_hwm[p])
            stats_queue_hwm[p] = qsz;

        if (inQueue[p].empty()) continue;

        bool ack_ok = (ack_in_ports[p]->read() == level_in[p]);
        bool buf_ok = (buf_status_ports[p]->read().mask[0] == false);
        if (ack_ok && buf_ok) {
            flit_in_ports[p]->write(inQueue[p].front());
            inQueue[p].pop();
            level_in[p] = !level_in[p];
            req_in_ports[p]->write(level_in[p]);
        }
    }
}

// ============================================================
// rxProcess: 从 NoC 边界接收 flit；跨芯片的写入 out_file
// 每个 packet 只写一条记录（HEAD flit 触发），包含 sequence_length
// ============================================================
void FileIO::rxProcess()
{
    if (reset.read()) {
        for (int p = 0; p < total_ports; p++) {
            ack_out_ports[p]->write(false);
            level_out[p] = false;
        }
        return;
    }

    for (int p = 0; p < total_ports; p++) {
        if (req_out_ports[p]->read() != level_out[p]) {
            Flit f = flit_out_ports[p]->read();
            level_out[p] = !level_out[p];
            ack_out_ports[p]->write(level_out[p]);

            // 跨芯片 flit：仅在 HEAD 时写一条记录
            if (f.dst_chip_id >= 0 && f.dst_chip_id != chip_id &&
                f.flit_type == FLIT_TYPE_HEAD) {
                int now_cycle = (int)(sc_time_stamp().to_double() / GlobalParams::clock_period_ps);
                writeRecord(f.chip_id, f.dst_chip_id, f.src_id, f.dst_id,
                            now_cycle, f.sequence_length);
                stats_tx_to_file++;
            }
        }
    }
}

// ============================================================
// fileReaderThread: SC_THREAD，每个时钟沿轮询 in_file
//   1. 读取新行，解析后存入 pending_（按 inject_cycle 排序）
//   2. 将到期的 pending flit 推入 inQueue
// ============================================================
void FileIO::fileReaderThread()
{
    wait(); // 等待第一个时钟沿（reset 释放后）

    while (true) {
        {
            auto parseOneLine = [&](const string& line) {
                if (line.empty() || line[0] == '#') return;
                if (line == "TICK_T_DONE")          return; // barrier: 暂未实现

                int src_chip, dst_chip, src_pe, dst_pe, inject_cycle;
                int seq_len = 2; // 默认 2-flit 包
                int parsed = sscanf(line.c_str(), "%d %d %d %d %d %d",
                    &src_chip, &dst_chip, &src_pe, &dst_pe, &inject_cycle, &seq_len);
                if (parsed < 5) return;
                stats_records_parsed++;

                int port = nearestBoundaryPort(dst_pe);

                // Non-local destination:
                // - inbox mode: direct-write to destination inbox
                // - ring mode: hop-by-hop forwarding to next chip
                if (dst_chip != chip_id) {
                    writeRecord(src_chip, dst_chip, src_pe, dst_pe,
                                inject_cycle, seq_len);
                    stats_tx_to_file++;
                    return;
                }

                // 构造 HEAD flit (local destination after forwarding)
                Flit head;
                head.src_id            = src_pe;
                head.dst_id            = dst_pe;
                head.chip_id           = src_chip;
                head.dst_chip_id       = chip_id;
                head.flit_type         = FLIT_TYPE_HEAD;
                head.sequence_no       = 0;
                head.sequence_length   = seq_len;
                head.vc_id             = 0;
                head.hop_no            = 0;
                head.timestamp         = (double)inject_cycle;
                head.use_low_voltage_path = false;
                head.hub_relay_node    = -1;

                // 构造 TAIL flit
                Flit tail            = head;
                tail.flit_type       = FLIT_TYPE_TAIL;
                tail.sequence_no     = seq_len - 1;

                PendingFlit pf_head  = { inject_cycle, head, port };
                PendingFlit pf_tail  = { inject_cycle, tail, port };

                // 插入 pending_，按 inject_cycle 排序；同 cycle 内 HEAD 先于 TAIL
                pending_.push_back(pf_head);
                pending_.push_back(pf_tail);
                stable_sort(pending_.begin(), pending_.end(),
                    [](const PendingFlit& a, const PendingFlit& b) {
                        if (a.inject_cycle != b.inject_cycle)
                            return a.inject_cycle < b.inject_cycle;
                        return a.flit.sequence_no < b.flit.sequence_no;
                    });
            };

            // Re-open every cycle at the last consumed offset.
            // This avoids stale EOF visibility issues on some filesystems when
            // another process is appending concurrently.
            int in_fd = open(in_path_.c_str(), O_RDONLY);
            if (in_fd >= 0) {
                if (lseek(in_fd, in_offset_, SEEK_SET) >= 0) {
                    char buf[4096];
                    while (true) {
                        ssize_t n = read(in_fd, buf, sizeof(buf));
                        if (n <= 0) break; // EOF (no new data yet) or read error
                        in_offset_ += (off_t)n;
                        in_partial_line_.append(buf, (size_t)n);

                        size_t start = 0;
                        while (true) {
                            size_t end = in_partial_line_.find('\n', start);
                            if (end == string::npos) break;
                            parseOneLine(in_partial_line_.substr(start, end - start));
                            start = end + 1;
                        }

                        if (start > 0)
                            in_partial_line_.erase(0, start);
                    }
                }
                close(in_fd);
            }
        }

        // 将已到期的 flit 推入 inQueue
        int now_cycle = (int)(sc_time_stamp().to_double() / GlobalParams::clock_period_ps);
        while (!pending_.empty() && pending_.front().inject_cycle <= now_cycle) {
            PendingFlit& pf = pending_.front();
            pf.flit.timestamp = (double)now_cycle; // 更新为实际注入时刻
            manualInject(pf.port, pf.flit);
            stats_rx_from_file++;
            pending_.erase(pending_.begin());
        }

        wait(); // 等待下一个时钟沿
    }
}

// ============================================================
// manualInject: 将 flit 压入指定 port 的 inQueue
// ============================================================
void FileIO::manualInject(int port, Flit flit)
{
    if (port < 0 || port >= total_ports) return;
    inQueue[port].push(flit);
}

// ============================================================
// port2Coord: 边界端口编号 -> (x, y, 方向)
//   顺时针: N[0..dimx-1], E[dimx..dimx+dimy-1],
//           S[dimx+dimy..2dimx+dimy-1], W[2dimx+dimy..]
// ============================================================
void FileIO::port2Coord(int p, int& x, int& y, int& dir)
{
    int dimx = GlobalParams::mesh_dim_x;
    int dimy = GlobalParams::mesh_dim_y;
    if (p < dimx) {
        x = p;        y = 0;        dir = DIRECTION_NORTH;
    } else if (p < dimx + dimy) {
        x = dimx - 1; y = p - dimx; dir = DIRECTION_EAST;
    } else if (p < 2 * dimx + dimy) {
        x = dimx - (p - (dimx + dimy)) - 1; y = dimy - 1; dir = DIRECTION_SOUTH;
    } else {
        x = 0; y = dimy - (p - (2 * dimx + dimy)) - 1; dir = DIRECTION_WEST;
    }
}

// ============================================================
// nearestBoundaryPort: 选择距 dst_pe 最近的边界端口
// ============================================================
int FileIO::nearestBoundaryPort(int dst_pe)
{
    int dimx  = GlobalParams::mesh_dim_x;
    int dimy  = GlobalParams::mesh_dim_y;
    int dst_x = dst_pe % dimx;
    int dst_y = dst_pe / dimx;

    int d_north = dst_y;
    int d_south = (dimy - 1) - dst_y;
    int d_west  = dst_x;
    int d_east  = (dimx - 1) - dst_x;

    int best = min({d_north, d_south, d_west, d_east});

    if (best == d_north) return dst_x;
    if (best == d_east)  return dimx + dst_y;
    if (best == d_south) return dimx + dimy + (dimx - 1 - dst_x);
    /* west */           return 2 * dimx + dimy + (dimy - 1 - dst_y);
}

// ============================================================
// connectAll: 将端口数组连接到单个 NoC 的边界 router 信号
//   方向约定与 ChipIO::connectAll 完全一致
// ============================================================
void FileIO::connectAll(NoC* noc)
{
    for (int p = 0; p < total_ports; p++) {
        int x, y, dir;
        port2Coord(p, x, y, dir);
        switch (dir) {
            case DIRECTION_NORTH:
                (*flit_in_ports   [p])(noc->flit[x][y].south);
                (*req_in_ports    [p])(noc->req [x][y].south);
                (*ack_in_ports    [p])(noc->ack [x][y].north);
                (*flit_out_ports  [p])(noc->flit[x][y].north);
                (*req_out_ports   [p])(noc->req [x][y].north);
                (*ack_out_ports   [p])(noc->ack [x][y].south);
                (*buf_status_ports[p])(noc->buffer_full_status[x][y].north);
                break;
            case DIRECTION_EAST:
                (*flit_in_ports   [p])(noc->flit[x][y].west);
                (*req_in_ports    [p])(noc->req [x][y].west);
                (*ack_in_ports    [p])(noc->ack [x][y].east);
                (*flit_out_ports  [p])(noc->flit[x][y].east);
                (*req_out_ports   [p])(noc->req [x][y].east);
                (*ack_out_ports   [p])(noc->ack [x][y].west);
                (*buf_status_ports[p])(noc->buffer_full_status[x][y].east);
                break;
            case DIRECTION_SOUTH:
                (*flit_in_ports   [p])(noc->flit[x][y].north);
                (*req_in_ports    [p])(noc->req [x][y].north);
                (*ack_in_ports    [p])(noc->ack [x][y].south);
                (*flit_out_ports  [p])(noc->flit[x][y].south);
                (*req_out_ports   [p])(noc->req [x][y].south);
                (*ack_out_ports   [p])(noc->ack [x][y].north);
                (*buf_status_ports[p])(noc->buffer_full_status[x][y].south);
                break;
            case DIRECTION_WEST:
                (*flit_in_ports   [p])(noc->flit[x][y].east);
                (*req_in_ports    [p])(noc->req [x][y].east);
                (*ack_in_ports    [p])(noc->ack [x][y].west);
                (*flit_out_ports  [p])(noc->flit[x][y].west);
                (*req_out_ports   [p])(noc->req [x][y].west);
                (*ack_out_ports   [p])(noc->ack [x][y].east);
                (*buf_status_ports[p])(noc->buffer_full_status[x][y].west);
                break;
        }
    }
}

// ============================================================
// crossOutThread: SC_THREAD
//   读 cross_out_path_ 文件，过滤 src_chip == chip_id 的记录，
//   立即写入 out_file_（保留 inject_cycle，由接收端按周期注入）。
//   另一个进程的 fileReaderThread 从 in_fifo 读到后注入本地 mesh。
// ============================================================
void FileIO::crossOutThread()
{
    wait(); // 等待 reset 释放

    ifstream f(cross_out_path_);
    if (!f.is_open()) {
        cerr << "[FileIO] crossOutThread: cannot open cross_out file: "
             << cross_out_path_ << endl;
        return;
    }

    struct OutEntry {
        int src_chip, dst_chip, src_pe, dst_pe, inject_cycle, seq_len;
    };
    vector<OutEntry> entries;

    string line;
    while (getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        OutEntry e; e.seq_len = 2;
        int n = sscanf(line.c_str(), "%d %d %d %d %d %d",
            &e.src_chip, &e.dst_chip, &e.src_pe, &e.dst_pe, &e.inject_cycle, &e.seq_len);
        if (n < 5) continue;
        if (e.src_chip != chip_id) continue; // 只处理本芯片的发送记录
        entries.push_back(e);
    }

    sort(entries.begin(), entries.end(), [](const OutEntry& a, const OutEntry& b) {
        return a.inject_cycle < b.inject_cycle;
    });

    cout << "[FileIO chip " << chip_id << "] crossOutThread: "
         << entries.size() << " outgoing entries loaded." << endl;

    for (auto& e : entries) {
        // Free-running mode for pre-computed traffic:
        // dump all records immediately, and let the receiver inject by
        // inject_cycle. This avoids wall-clock skew across processes where
        // a fast consumer might finish simulation before a slow producer
        // reaches later timesteps.
        writeRecord(e.src_chip, e.dst_chip, e.src_pe, e.dst_pe,
                    e.inject_cycle, e.seq_len);
        stats_tx_to_file++;
    }
}

// ============================================================
// writeRecord: thread-safe + cross-process-safe record writer
//
// Lock order:
//   1. out_mutex_  — serialises concurrent OS threads in THIS process
//                    (current SystemC is single-threaded, but future PE
//                     computation may call this from a real thread)
//   2. flock LOCK_EX — serialises concurrent PROCESSES writing to the same
//                    out_fifo path (e.g., two chips sharing a file)
//
// On Linux, write() for < PIPE_BUF (4096) bytes to a regular file is
// already atomic at the VFS level, so readers never see a partial line.
// flock provides an additional advisory lock for correctness when multiple
// processes share the same output file in future configurations.
// ============================================================
void FileIO::writeRecord(int src_chip, int dst_chip, int src_pe, int dst_pe,
                         int inject_cycle, int seq_len)
{
    lock_guard<mutex> lk(out_mutex_);          // (1) in-process serialisation

    if (inbox_mode_) {
        string target = inbox_dir_ + "/chip" + to_string(dst_chip) + "_in.txt";
        int fd = open(target.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) {
            cerr << "[FileIO] WARNING: cannot open inbox file: " << target << endl;
            return;
        }
        flock(fd, LOCK_EX);
        string rec = to_string(src_chip) + " " + to_string(dst_chip) + " "
                   + to_string(src_pe) + " " + to_string(dst_pe) + " "
                   + to_string(inject_cycle) + " " + to_string(seq_len) + "\n";
        ssize_t n = write(fd, rec.c_str(), rec.size());
        (void)n;
        flock(fd, LOCK_UN);
        close(fd);
    } else {
        if (out_fd_ >= 0)
            flock(out_fd_, LOCK_EX);               // (2) cross-process advisory lock

        if (out_file_.is_open()) {
            out_file_ << src_chip    << " " << dst_chip << " "
                      << src_pe      << " " << dst_pe   << " "
                      << inject_cycle << " " << seq_len  << "\n";
            out_file_.flush();
        }

        if (out_fd_ >= 0)
            flock(out_fd_, LOCK_UN);
    }
}

// ============================================================
// printStats
// ============================================================
void FileIO::printStats() const
{
    cout << "\n========== FileIO Statistics (chip " << chip_id << ") ==========" << endl;
    cout << "Packets written to out_fifo           : " << stats_tx_to_file   << endl;
    cout << "Packet records parsed from in_fifo    : " << stats_records_parsed << endl;
    cout << "Flits read from in_fifo and injected  : " << stats_rx_from_file << endl;
    cout << "Input file read offset (bytes)        : " << in_offset_ << endl;
    cout << "Pending (uninjected) flits at end     : " << pending_.size()    << endl;

    cout << "Injection queue high-water mark (non-zero ports):" << endl;
    for (int p = 0; p < total_ports; p++)
        if (stats_queue_hwm[p] > 0)
            cout << "  port " << p << " : hwm=" << stats_queue_hwm[p] << endl;

    cout << "================================================\n" << endl;
}
