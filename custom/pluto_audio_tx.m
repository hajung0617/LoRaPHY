% Transmit an MP3 file as LoRaPHY packets using one PlutoSDR.
% Start pluto_audio_rx.m in a second MATLAB session before running this.

script_dir = fileparts(mfilename('fullpath'));
addpath(fileparts(script_dir));

input_file = fullfile(script_dir, '..', 'files', 'sample-10s.mp3');
radio_id = 'usb:0'; % Confirm with findPlutoRadio in this MATLAB session.
rf_freq = 915e6;    % Match the configured Pluto center frequency.
sf = 7;
bw = 125e3;
fs = 1e6;
tx_gain = -30;       % Gain used by the working text link.
inter_packet_gap_s = 0.5; % Give the RX software more time between packets.

% LoRaPHY's decoder buffer is limited to 255 bytes including the 2 CRC bytes.
max_phy_payload_bytes = 253;
packet_index_bytes = 4;
packet_count_bytes = 4;
file_size_bytes = 4;
data_bytes_per_packet = max_phy_payload_bytes - packet_index_bytes - ...
    packet_count_bytes - file_size_bytes;

fid = fopen(input_file, 'rb');
if fid < 0
    error('Cannot open input file: %s', input_file);
end
file_bytes = fread(fid, inf, '*uint8');
fclose(fid);
if numel(file_bytes) > double(intmax('uint32'))
    error('Input file is too large for the packet header.');
end

packet_count = ceil(numel(file_bytes) / data_bytes_per_packet);
phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;
phy.cr = 1;         % Coding rate 4/5.
phy.crc = 1;
phy.preamble_len = 8;

% Use one fixed-length frame for every call to the Pluto TX object.
probe_symbols = phy.encode(zeros(max_phy_payload_bytes, 1, 'uint8'));
probe_signal = phy.modulate(probe_symbols);
frame_length = numel(probe_signal) + round(inter_packet_gap_s * fs);
clear probe_symbols probe_signal;

fprintf('File: %s (%d bytes), %d packets (%d data bytes/packet max)\n', ...
    input_file, numel(file_bytes), packet_count, data_bytes_per_packet);
fprintf('Pluto TX RadioID: %s, center frequency: %.3f MHz\n', radio_id, rf_freq/1e6);
fprintf('Run the receiver first; then press Enter here to transmit.\n');
pause;

tx = sdrtx('Pluto', ...
    'RadioID', radio_id, ...
    'CenterFrequency', rf_freq, ...
    'BasebandSampleRate', fs, ...
    'Gain', tx_gain);
tx_cleanup = onCleanup(@() release(tx));
disp(info(tx));

for packet_idx = 1:packet_count
    first = (packet_idx - 1) * data_bytes_per_packet + 1;
    last = min(packet_idx * data_bytes_per_packet, numel(file_bytes));
    chunk = file_bytes(first:last);
    packet_payload = [ ...
        typecast(uint32(packet_idx), 'uint8')'; ...
        typecast(uint32(packet_count), 'uint8')'; ...
        typecast(uint32(numel(file_bytes)), 'uint8')'; ...
        chunk(:)];

    tx_symbols = phy.encode(packet_payload);
    tx_signal = phy.modulate(tx_symbols);
    tx_frame = complex(zeros(frame_length, 1));
    tx_frame(1:numel(tx_signal)) = tx_signal(:);
    peak = max(abs(tx_frame));
    if peak > 0
        tx_frame = 0.7 * tx_frame / peak;
    end

    tx(tx_frame);
    fprintf('Transmitted packet %d/%d\n', packet_idx, packet_count);
end

% Retry only the tail packet; RX ignores duplicates and can recover a missed tail.
packet_idx = packet_count;
first = (packet_idx - 1) * data_bytes_per_packet + 1;
last = min(packet_idx * data_bytes_per_packet, numel(file_bytes));
chunk = file_bytes(first:last);
packet_payload = [ ...
    typecast(uint32(packet_idx), 'uint8')'; ...
    typecast(uint32(packet_count), 'uint8')'; ...
    typecast(uint32(numel(file_bytes)), 'uint8')'; ...
    chunk(:)];
tail_symbols = phy.encode(packet_payload);
tail_signal = phy.modulate(tail_symbols);
tail_frame = complex(zeros(frame_length, 1));
tail_frame(1:numel(tail_signal)) = tail_signal(:);
peak = max(abs(tail_frame));
if peak > 0
    tail_frame = 0.7 * tail_frame / peak;
end
tx(tail_frame);
fprintf('Retried final packet %d/%d\n', packet_idx, packet_count);

% Give the receiver time to drain the final samples before TX is released.
tx(complex(zeros(frame_length, 1)));
pause(frame_length/fs);
release(tx);
fprintf('Transmission complete; trailing silence sent.\n');
