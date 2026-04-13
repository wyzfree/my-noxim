#include "ChipIO.h"
#include <cstdio>
using namespace std;

ChipIO::ChipIO(sc_module_name name, vector<NoC*>& noc_chips) : sc_module(name)
{
    SC_METHOD(process);
    sensitive << reset;
    sensitive << clock.pos();

    num_chips   = (int)noc_chips.size();
    total_ports = 2 * (GlobalParams::mesh_dim_x + GlobalParams::mesh_dim_y);
    int N = num_chips * total_ports;

    flit_in_ports   = new sc_out<Flit>*             [N];
    req_in_ports    = new sc_out<bool>*             [N];
    ack_in_ports    = new sc_in<bool>*              [N];
    buf_status_ports= new sc_in<TBufferFullStatus>* [N];
    flit_out_ports  = new sc_in<Flit>*              [N];
    req_out_ports   = new sc_in<bool>*              [N];
    ack_out_ports   = new sc_out<bool>*             [N];

    for (int i = 0; i < N; i++) {
        char buf[64];
        sprintf(buf, "flit_in_%d",    i); flit_in_ports   [i] = new sc_out<Flit>(buf);
        sprintf(buf, "req_in_%d",     i); req_in_ports    [i] = new sc_out<bool>(buf);
        sprintf(buf, "ack_in_%d",     i); ack_in_ports    [i] = new sc_in<bool>(buf);
        sprintf(buf, "buf_status_%d", i); buf_status_ports[i] = new sc_in<TBufferFullStatus>(buf);
        sprintf(buf, "flit_out_%d",   i); flit_out_ports  [i] = new sc_in<Flit>(buf);
        sprintf(buf, "req_out_%d",    i); req_out_ports   [i] = new sc_in<bool>(buf);
        sprintf(buf, "ack_out_%d",    i); ack_out_ports   [i] = new sc_out<bool>(buf);
    }

    level_in .assign(num_chips, vector<bool>(total_ports, false));
    level_out.assign(num_chips, vector<bool>(total_ports, false));
    inQueue  .assign(num_chips, vector<queue<Flit>>(total_ports));

    stats_tx.assign(num_chips, vector<int>(num_chips, 0));
    stats_rx_from_noc.assign(num_chips, 0);
    stats_queue_hwm.assign(num_chips, vector<int>(total_ports, 0));

    connectAll(noc_chips);

    if (!GlobalParams::cross_traffic_filename.empty())
        loadCrossTraffic(GlobalParams::cross_traffic_filename);

    SC_THREAD(crossTrafficThread);
    sensitive << clock.pos();
}

void ChipIO::loadCrossTraffic(const string& filename)
{
    ifstream f(filename);
    if (!f.is_open()) {
        cerr << "ChipIO: cannot open cross_traffic file: " << filename << endl;
        return;
    }
    string line;
    while (getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        CrossTrafficEntry e;
        if (sscanf(line.c_str(), "%d %d %d %d %d",
                   &e.src_chip, &e.dst_chip, &e.src_pe, &e.dst_pe, &e.inject_cycle) == 5)
            cross_traffic.push_back(e);
    }
    cout << "ChipIO: loaded " << cross_traffic.size() << " cross-chip traffic entries." << endl;
}

void ChipIO::crossTrafficThread()
{
    // Wait until reset is released
    wait();
    for (auto& e : cross_traffic) {
        // Wait until the target cycle
        double target_ps = (double)e.inject_cycle * GlobalParams::clock_period_ps;
        double now_ps    = sc_time_stamp().to_double();
        if (target_ps > now_ps)
            wait(target_ps - now_ps, SC_PS);

        // Build a minimal 2-flit packet (HEAD + TAIL)
        Flit head, tail;
        head.src_id    = e.src_pe;
        head.dst_id    = e.dst_pe;
        head.chip_id   = e.src_chip;
        head.dst_chip_id = e.dst_chip;
        head.flit_type = FLIT_TYPE_HEAD;
        head.sequence_no     = 0;
        head.sequence_length = 2;
        head.vc_id     = 0;
        head.hop_no    = 0;
        // timestamp in cycles (not ps) to match Noxim's delay calculation
        head.timestamp = sc_time_stamp().to_double() / GlobalParams::clock_period_ps;
        head.use_low_voltage_path = false;
        head.hub_relay_node = -1;

        tail = head;
        tail.flit_type   = FLIT_TYPE_TAIL;
        tail.sequence_no = 1;

        // Select nearest boundary port to dst_pe to minimize intra-chip hops
        int inject_port = nearestBoundaryPort(e.dst_pe);

        // Inject directly into dst_chip boundary (ChipIO acts as direct bridge)
        cout << "[ChipIO] injecting cross-chip: chip " << e.src_chip
             << " -> chip " << e.dst_chip
             << "  src_pe=" << e.src_pe << " dst_pe=" << e.dst_pe
             << "  port=" << inject_port
             << "  @" << sc_time_stamp() << endl;
        manualInject(e.dst_chip, inject_port, head);
        manualInject(e.dst_chip, inject_port, tail);

        // Record TX statistics
        if (e.src_chip >= 0 && e.src_chip < num_chips &&
            e.dst_chip >= 0 && e.dst_chip < num_chips)
            stats_tx[e.src_chip][e.dst_chip]++;
    }
}

void ChipIO::process()
{
    txProcess();
    rxProcess();
    dispatchCrossChip();
}

void ChipIO::txProcess()
{
    if (reset.read()) {
        for (int c = 0; c < num_chips; c++)
            for (int p = 0; p < total_ports; p++) {
                req_in_ports[c*total_ports+p]->write(false);
                level_in[c][p] = false;
            }
        return;
    }
    for (int c = 0; c < num_chips; c++)
        for (int p = 0; p < total_ports; p++) {
            // Track queue high-water mark
            int qsz = (int)inQueue[c][p].size();
            if (qsz > stats_queue_hwm[c][p])
                stats_queue_hwm[c][p] = qsz;

            if (inQueue[c][p].empty()) continue;
            int idx = c * total_ports + p;
            bool ack_ok = (ack_in_ports[idx]->read() == level_in[c][p]);
            bool buf_ok = (buf_status_ports[idx]->read().mask[0] == false);
            if (ack_ok && buf_ok) {
                flit_in_ports[idx]->write(inQueue[c][p].front());
                inQueue[c][p].pop();
                level_in[c][p] = !level_in[c][p];
                req_in_ports[idx]->write(level_in[c][p]);
            }
        }
}

void ChipIO::rxProcess()
{
    if (reset.read()) {
        for (int c = 0; c < num_chips; c++)
            for (int p = 0; p < total_ports; p++) {
                ack_out_ports[c*total_ports+p]->write(false);
                level_out[c][p] = false;
            }
        return;
    }
    for (int c = 0; c < num_chips; c++)
        for (int p = 0; p < total_ports; p++) {
            int idx = c * total_ports + p;
            if (req_out_ports[idx]->read() != level_out[c][p]) {
                Flit f = flit_out_ports[idx]->read();
                rxBuffer.push(make_pair(f, make_pair(c, p)));
                level_out[c][p] = !level_out[c][p];
                ack_out_ports[idx]->write(level_out[c][p]);
                stats_rx_from_noc[c]++;
            }
        }
}

void ChipIO::dispatchCrossChip()
{
    while (!rxBuffer.empty()) {
        auto item = rxBuffer.front(); rxBuffer.pop();
        Flit f      = item.first;
        int from_c  = item.second.first;
        int dst_chip = f.dst_chip_id;
        if (dst_chip < 0 || dst_chip == from_c || dst_chip >= num_chips) continue;
        // Record cross-chip hop latency (cycles from src_pe send to ChipIO dispatch)
        double now_cycle = sc_time_stamp().to_double() / GlobalParams::clock_period_ps;
        if (f.timestamp > 0 && now_cycle >= f.timestamp)
            stats_cross_latency.push_back(now_cycle - f.timestamp);
        int inject_port = nearestBoundaryPort(f.dst_id);
        cout << "[ChipIO] cross-chip flit: chip " << from_c
             << " -> chip " << dst_chip
             << "  src_pe=" << f.src_id << " dst_pe=" << f.dst_id
             << "  port=" << inject_port
             << "  type=" << f.flit_type
             << "  @" << sc_time_stamp() << endl;
        inQueue[dst_chip][inject_port].push(f);
    }
}

void ChipIO::manualInject(int chip_id, int port, Flit flit)
{
    if (chip_id < 0 || chip_id >= num_chips) return;
    if (port  < 0 || port  >= total_ports)  return;
    inQueue[chip_id][port].push(flit);
}

void ChipIO::port2Coord(int p, int& x, int& y, int& dir)
{
    int dimx = GlobalParams::mesh_dim_x;
    int dimy = GlobalParams::mesh_dim_y;
    if (p < dimx) {
        x = p; y = 0; dir = DIRECTION_NORTH;
    } else if (p < dimx + dimy) {
        x = dimx-1; y = p-dimx; dir = DIRECTION_EAST;
    } else if (p < 2*dimx + dimy) {
        x = dimx-(p-(dimx+dimy))-1; y = dimy-1; dir = DIRECTION_SOUTH;
    } else {
        x = 0; y = dimy-(p-(2*dimx+dimy))-1; dir = DIRECTION_WEST;
    }
}

void ChipIO::printStats() const
{
    cout << "\n========== ChipIO Statistics ==========" << endl;

    // Per-link TX counts
    cout << "Cross-chip flit TX (packets injected by crossTrafficThread):" << endl;
    int total_tx = 0;
    for (int s = 0; s < num_chips; s++)
        for (int d = 0; d < num_chips; d++)
            if (stats_tx[s][d] > 0) {
                cout << "  chip " << s << " -> chip " << d
                     << " : " << stats_tx[s][d] << " pkts" << endl;
                total_tx += stats_tx[s][d];
            }
    cout << "  Total TX packets: " << total_tx << endl;

    // Per-chip RX from NoC boundary
    cout << "Flits captured from NoC boundary by ChipIO:" << endl;
    for (int c = 0; c < num_chips; c++)
        cout << "  chip " << c << " : " << stats_rx_from_noc[c] << " flits" << endl;

    // Cross-chip hop latency
    if (!stats_cross_latency.empty()) {
        double sum = 0, mx = 0;
        for (double v : stats_cross_latency) { sum += v; if (v > mx) mx = v; }
        cout << "Cross-chip hop latency (src_pe send -> ChipIO dispatch):" << endl;
        cout << "  Samples : " << stats_cross_latency.size() << endl;
        cout << "  Avg     : " << sum / stats_cross_latency.size() << " cycles" << endl;
        cout << "  Max     : " << mx << " cycles" << endl;
    }

    // Queue high-water mark (top 5 busiest ports)
    cout << "Injection queue high-water mark (non-zero ports):" << endl;
    for (int c = 0; c < num_chips; c++)
        for (int p = 0; p < total_ports; p++)
            if (stats_queue_hwm[c][p] > 0)
                cout << "  chip " << c << " port " << p
                     << " : hwm=" << stats_queue_hwm[c][p] << endl;

    cout << "========================================\n" << endl;
}

// Select the nearest boundary port for dst_pe.
// Strategy: pick the border (N/E/S/W) whose midpoint is closest to dst_pe,
// then pick the exact port on that border closest to dst_pe's coordinate.
int ChipIO::nearestBoundaryPort(int dst_pe)
{
    int dimx = GlobalParams::mesh_dim_x;
    int dimy = GlobalParams::mesh_dim_y;
    int dst_x = dst_pe % dimx;
    int dst_y = dst_pe / dimx;

    // Distance from pe to each border
    int d_north = dst_y;                  // distance to y=0
    int d_south = (dimy - 1) - dst_y;     // distance to y=dimy-1
    int d_west  = dst_x;                  // distance to x=0
    int d_east  = (dimx - 1) - dst_x;     // distance to x=dimx-1

    int best = min({d_north, d_south, d_west, d_east});

    // Port numbering (clockwise): N[0..dimx-1], E[dimx..dimx+dimy-1],
    //                             S[dimx+dimy..2dimx+dimy-1], W[2dimx+dimy..]
    if (best == d_north) return dst_x;                        // N border, column dst_x
    if (best == d_east)  return dimx + dst_y;                 // E border, row dst_y
    if (best == d_south) return dimx + dimy + (dimx-1-dst_x); // S border (right-to-left)
    /* west */           return 2*dimx + dimy + (dimy-1-dst_y); // W border (bottom-to-top)
}

void ChipIO::connectAll(vector<NoC*>& noc_chips)
{
    for (int c = 0; c < num_chips; c++) {
        NoC* noc = noc_chips[c];
        for (int p = 0; p < total_ports; p++) {
            int idx = c * total_ports + p;
            int x, y, dir;
            port2Coord(p, x, y, dir);
            switch (dir) {
                case DIRECTION_NORTH:
                    (*flit_in_ports [idx])(noc->flit[x][y].south);
                    (*req_in_ports  [idx])(noc->req [x][y].south);
                    (*ack_in_ports  [idx])(noc->ack [x][y].north);
                    (*flit_out_ports[idx])(noc->flit[x][y].north);
                    (*req_out_ports [idx])(noc->req [x][y].north);
                    (*ack_out_ports [idx])(noc->ack [x][y].south);
                    (*buf_status_ports[idx])(noc->buffer_full_status[x][y].north);
                    break;
                case DIRECTION_EAST:
                    (*flit_in_ports [idx])(noc->flit[x][y].west);
                    (*req_in_ports  [idx])(noc->req [x][y].west);
                    (*ack_in_ports  [idx])(noc->ack [x][y].east);
                    (*flit_out_ports[idx])(noc->flit[x][y].east);
                    (*req_out_ports [idx])(noc->req [x][y].east);
                    (*ack_out_ports [idx])(noc->ack [x][y].west);
                    (*buf_status_ports[idx])(noc->buffer_full_status[x][y].east);
                    break;
                case DIRECTION_SOUTH:
                    (*flit_in_ports [idx])(noc->flit[x][y].north);
                    (*req_in_ports  [idx])(noc->req [x][y].north);
                    (*ack_in_ports  [idx])(noc->ack [x][y].south);
                    (*flit_out_ports[idx])(noc->flit[x][y].south);
                    (*req_out_ports [idx])(noc->req [x][y].south);
                    (*ack_out_ports [idx])(noc->ack [x][y].north);
                    (*buf_status_ports[idx])(noc->buffer_full_status[x][y].south);
                    break;
                case DIRECTION_WEST:
                    (*flit_in_ports [idx])(noc->flit[x][y].east);
                    (*req_in_ports  [idx])(noc->req [x][y].east);
                    (*ack_in_ports  [idx])(noc->ack [x][y].west);
                    (*flit_out_ports[idx])(noc->flit[x][y].west);
                    (*req_out_ports [idx])(noc->req [x][y].west);
                    (*ack_out_ports [idx])(noc->ack [x][y].east);
                    (*buf_status_ports[idx])(noc->buffer_full_status[x][y].west);
                    break;
            }
        }
    }
}
