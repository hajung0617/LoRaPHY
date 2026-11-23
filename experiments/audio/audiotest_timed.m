% Timed software loopback for a short audio sample using LoRaPHY.
% The timing covers packet encode/modulate/demodulate/decode and validation.

script_dir = fileparts(mfilename('fullpath'));
project_dir = fileparts(fileparts(script_dir));
addpath(project_dir);
result_dir = fullfile(fileparts(fileparts(script_dir)), 'experiments', 'results', 'audio');
if ~exist(result_dir, 'dir'), mkdir(result_dir); end
run_timestamp = char(datetime('now', 'Format', 'yyMMdd_HHmmss_SSS'));

input_audio = fullfile(fileparts(fileparts(script_dir)), 'data', 'experiments', 'audio', 'sample-3s.mp3');
output_audio = fullfile(result_dir, ['audio_received_timed_' run_timestamp '.wav']);

rf_freq = 470e6; % Required by the current LoRaPHY constructor; unused by software loopback.
sf = 7;
bw = 125e3;
fs = 1e6;
max_payload_bytes = 253; % Decoder limit includes two CRC bytes.
packet_index_bytes = 4;
audio_bytes_per_packet = max_payload_bytes - packet_index_bytes;
audio_sample_rate = 8000;

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;
phy.cr = 4;
phy.crc = 1;
phy.preamble_len = 8;

% Prepare application data before starting the PHY processing timer.
[audio, source_fs] = audioread(input_audio);
audio = resample(mean(audio, 2), audio_sample_rate, source_fs);
audio_bytes = uint8(round(max(-1, min(1, audio)) * 127.5 + 127.5));
packet_count = ceil(numel(audio_bytes) / audio_bytes_per_packet);
received_bytes = zeros(0, 1, 'uint8');
packet_times = zeros(packet_count, 1);

fprintf('Timed internal LoRaPHY loopback: %d bytes in %d packets\n', ...
    numel(audio_bytes), packet_count);
loopback_timer = tic;
for packet_idx = 1:packet_count
    packet_timer = tic;
    first = (packet_idx - 1) * audio_bytes_per_packet + 1;
    last = min(packet_idx * audio_bytes_per_packet, numel(audio_bytes));
    packet_payload = [typecast(uint32(packet_idx), 'uint8')'; audio_bytes(first:last)];

    % Transmitter: application bytes -> LoRa symbols -> baseband chirps.
    tx_symbols = phy.encode(packet_payload);
    tx_signal = phy.modulate(tx_symbols);

    % Receiver: baseband chirps -> symbols -> application bytes.
    [rx_symbols, ~] = phy.demodulate(tx_signal);
    [rx_payload, crc_value] = phy.decode(rx_symbols);
    if isempty(rx_payload) || isempty(crc_value) || ...
            ~isequal(uint8(rx_payload(end-1:end)), uint8(crc_value(:)))
        error('Packet %d failed demodulation or CRC check.', packet_idx);
    end

    rx_payload = uint8(rx_payload(1:end-2)); % Strip the decoded CRC bytes.
    rx_packet_idx = typecast(rx_payload(1:packet_index_bytes), 'uint32');
    if rx_packet_idx ~= packet_idx
        error('Packet index mismatch: expected %d, received %d.', ...
            packet_idx, rx_packet_idx);
    end
    received_bytes = [received_bytes; rx_payload(packet_index_bytes+1:end)]; %#ok<AGROW>
    packet_times(packet_idx) = toc(packet_timer);
    fprintf('  Packet %d/%d: %.4f s (CRC checked)\n', ...
        packet_idx, packet_count, packet_times(packet_idx));
end
loopback_time = toc(loopback_timer);

received_audio = (double(received_bytes) - 127.5) / 127.5;
audiowrite(output_audio, received_audio, audio_sample_rate);

fprintf('PHY loopback processing time: %.4f s\n', loopback_time);
fprintf('Average processing time per packet: %.4f s\n', mean(packet_times));
fprintf('Audio duration: %.4f s; processing ratio: %.2fx real time\n', ...
    numel(audio_bytes) / audio_sample_rate, ...
    loopback_time / (numel(audio_bytes) / audio_sample_rate));
fprintf('Loopback complete. Reconstructed audio: %s\n', output_audio);
