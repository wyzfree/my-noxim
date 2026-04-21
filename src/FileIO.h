/*
 * FileIO - Multi-process cross-chip communication module
 *
 * Each noxim process runs ONE chip. Cross-chip flits are exchanged via files:
 *   in_fifo:  this chip reads incoming cross-chip flits from here
 *   out_fifo: this chip writes outgoing cross-chip flits here
 *
 * Free-running mode (default, for pre-computed traffic_table):
 *   Sender pre-dumps all outgoing records to out_fifo (inject_cycle kept).
 *   Reader injects at inject_cycle locally. No barrier needed.
 *
 * Barrier mode (for real PE computation):
 *   After each SNN timestep, write "TICK_T_DONE" to out_fifo.
 *   Reader waits for "TICK_T_DONE" before processing next timestep.
 *
 * File record format (one per line):
 *   src_chip  dst_chip  src_pe  dst_pe  inject_cycle
 *   or:
 *   TICK_T_DONE   (barrier marker)
 */

#ifndef __NOXIM_FILEIO_H__
#define __NOXIM_FILEIO_H__

#include <fstream>
#include <queue>
#include <string>
#include <mutex>
#include <systemc.h>
#include <sys/file.h>
#include "NoC.h"
#include "DataStructs.h"
#include "GlobalParams.h"

using namespace std;

SC_MODULE(FileIO)
{
    sc_in_clk   clock;
    sc_in<bool> reset;

    SC_HAS_PROCESS(FileIO);

    FileIO(sc_module_name name, NoC* noc,
           const string& in_fifo_path,
           const string& out_fifo_path,
           const string& cross_out_path = "");

    void printStats() const;

private:
    int    chip_id;
    int    total_ports;
    NoC*   noc_;
    string in_path_;
    string out_path_;
    bool   inbox_mode_;
    string inbox_dir_;

    // Dynamic port arrays indexed by boundary port number
    sc_out<Flit>**             flit_in_ports;
    sc_out<bool>**             req_in_ports;
    sc_in<bool>**              ack_in_ports;
    sc_in<TBufferFullStatus>** buf_status_ports;
    sc_in<Flit>**              flit_out_ports;
    sc_in<bool>**              req_out_ports;
    sc_out<bool>**             ack_out_ports;

    // ABP level tracking per port
    vector<bool> level_in;
    vector<bool> level_out;

    // Injection queues indexed by boundary port
    vector<queue<Flit>> inQueue;

    // Flits read from in_fifo waiting to be injected at the right cycle
    // sorted by inject_cycle
    struct PendingFlit {
        int inject_cycle;
        Flit flit;
        int port;
        bool operator>(const PendingFlit& o) const {
            return inject_cycle > o.inject_cycle;
        }
    };
    vector<PendingFlit> pending_;  // kept sorted by inject_cycle

    // File state
    off_t    in_offset_;       // current read offset in in_fifo
    string   in_partial_line_; // trailing partial line buffer for in_fifo
    int      out_fd_;          // raw fd for flock (cross-process locking)
    ofstream out_file_;
    string   cross_out_path_;

    // Mutex protecting out_file_ writes.
    // SystemC itself is single-threaded, but when PE computation logic runs
    // in a real OS thread (e.g., future spike generation), both that thread
    // and the SystemC callbacks may call writeRecord() concurrently.
    mutex    out_mutex_;

    // Statistics
    int stats_rx_from_file;      // flits read from in_fifo and injected
    int stats_tx_to_file;        // cross-chip flits written to out_fifo
    int stats_records_parsed;    // valid packet records parsed from in_fifo
    vector<int> stats_queue_hwm; // injection queue high-water mark per port

    void process();
    void txProcess();            // inject flits from inQueue into NoC
    void rxProcess();            // receive flits from NoC; write cross-chip ones to out_fifo
    void fileReaderThread();     // SC_THREAD: read in_fifo, enqueue pending flits
    void crossOutThread();       // SC_THREAD: write this chip's outgoing cross-chip traffic to out_fifo

    void connectAll(NoC* noc);
    static void port2Coord(int p, int& x, int& y, int& dir);
    static int  nearestBoundaryPort(int dst_pe);
    void manualInject(int port, Flit flit);

    // Thread-safe, cross-process-safe record writer.
    // Acquires out_mutex_ (for future PE threads) and flock LOCK_EX (for
    // concurrent processes sharing the same out_fifo path), then writes one
    // formatted record and flushes.  Safe to call from any context.
    void writeRecord(int src_chip, int dst_chip, int src_pe, int dst_pe,
                     int inject_cycle, int seq_len);
};

#endif
