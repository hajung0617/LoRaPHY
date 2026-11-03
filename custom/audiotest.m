% Packetize a short audio sample with LoRaPHY and reconstruct it from the
% generated baseband packets. This software loopback does not use a radio.

script_dir = fileparts(mfilename('fullpath'));
addpath(fileparts(script_dir));

input_audio = fullfile(script_dir, '..', 'files', 'sample-3s.mp3');
packet_file = fullfile(script_dir, 'audio_packets.mat');
output_audio = fullfile(script_dir, 'audio_received.wav');
mode = 'loopback'; % 'estimate' only measures; 'encode'/'decode' save and reload signals.

rf_freq = 470e6;
sf = 7;
bw = 125e3;
fs = 1e6;
% LoRaPHY's decoder stores at most 255 bytes, including the 2 CRC bytes.
% Keep the application payload at 253 bytes or less when CRC is enabled.
max_payload_bytes = 253;
packet_index_bytes = 4;
audio_bytes_per_packet = max_payload_bytes - packet_index_bytes;
audio_sample_rate = 8000; % Low-rate mono PCM keeps the packet count manageable.

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;
phy.cr = 4;
phy.crc = 1;
phy.preamble_len = 8;

switch mode
    case 'estimate'
        [audio, source_fs] = audioread(input_audio);
        audio = resample(mean(audio, 2), audio_sample_rate, source_fs);
        audio_byte_count = numel(audio); % 8-bit mono PCM: one byte per sample.
        packet_count = ceil(audio_byte_count / audio_bytes_per_packet);
        packet_payload_lengths = min(audio_bytes_per_packet, ...
            audio_byte_count - (0:packet_count-1)' * audio_bytes_per_packet) + packet_index_bytes;
        payload_symbols = 8 + (phy.cr + 4) * ceil((2 * packet_payload_lengths ...
            - phy.sf + 7 + 4 * phy.crc - 5 * (1 - phy.has_header)) ...
            / (phy.sf - 2 * phy.ldr));
        packet_symbols = payload_symbols + phy.preamble_len + 2 + 2.25;
        packet_airtime = packet_symbols * 2^phy.sf / phy.bw;
        audio_duration = audio_byte_count / audio_sample_rate;
        source_info = dir(input_audio);

        fprintf('Input file: %s (%d bytes)\n', input_audio, source_info.bytes);
        fprintf('Audio payload after 8 kHz mono conversion: %d bytes (%.2f seconds)\n', ...
            audio_byte_count, audio_duration);
        fprintf('Packets: %d (up to %d audio bytes + %d index bytes each)\n', ...
            packet_count, audio_bytes_per_packet, packet_index_bytes);
        fprintf('Estimated LoRa airtime: %.1f seconds (%.1fx audio duration)\n', ...
            sum(packet_airtime), sum(packet_airtime) / audio_duration);

    case 'loopback'
        % Read and convert audio to 8 kHz, mono, 8-bit PCM bytes.
        [audio, source_fs] = audioread(input_audio);
        audio = resample(mean(audio, 2), audio_sample_rate, source_fs);
        audio_bytes = uint8(round(max(-1, min(1, audio)) * 127.5 + 127.5));
        packet_count = ceil(numel(audio_bytes) / audio_bytes_per_packet);
        received_bytes = zeros(0, 1, 'uint8');

        fprintf('Internal LoRaPHY loopback: %d bytes in %d packets\n', ...
            numel(audio_bytes), packet_count);
        for packet_idx = 1:packet_count
            first = (packet_idx - 1) * audio_bytes_per_packet + 1;
            last = min(packet_idx * audio_bytes_per_packet, numel(audio_bytes));
            packet_payload = [typecast(uint32(packet_idx), 'uint8')'; audio_bytes(first:last)];

            % Transmitter: application bytes -> LoRa symbols -> baseband chirps.
            tx_symbols = phy.encode(packet_payload);
            tx_signal = phy.modulate(tx_symbols);

            % Internal channel: pass the generated signal directly to receiver.
            % Add noise or other channel effects here for a non-ideal test.

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
            fprintf('  Packet %d/%d received and CRC-checked\n', packet_idx, packet_count);
        end

        received_audio = (double(received_bytes) - 127.5) / 127.5;
        audiowrite(output_audio, received_audio, audio_sample_rate);
        fprintf('Loopback complete. Reconstructed audio: %s\n', output_audio);

    case 'encode'
        [audio, source_fs] = audioread(input_audio);
        audio = mean(audio, 2); % Convert stereo input to mono.
        audio = resample(audio, audio_sample_rate, source_fs);
        audio_bytes = uint8(round(max(-1, min(1, audio)) * 127.5 + 127.5));
        packet_count = ceil(numel(audio_bytes) / audio_bytes_per_packet);
        baseband_packets = cell(packet_count, 1);

        for packet_idx = 1:packet_count
            first = (packet_idx - 1) * audio_bytes_per_packet + 1;
            last = min(packet_idx * audio_bytes_per_packet, numel(audio_bytes));
            packet_payload = [typecast(uint32(packet_idx), 'uint8')'; audio_bytes(first:last)];
            symbols = phy.encode(packet_payload);
            baseband_packets{packet_idx} = phy.modulate(symbols);
        end

        save(packet_file, 'baseband_packets', 'audio_sample_rate', '-v7.3');
        fprintf('Created %d baseband packets in %s\n', packet_count, packet_file);

    case 'decode'
        saved = load(packet_file);
        received_bytes = uint8([]);
        for packet_idx = 1:numel(saved.baseband_packets)
            [symbols_rx, ~] = phy.demodulate(saved.baseband_packets{packet_idx});
            [packet_rx, checksum] = phy.decode(symbols_rx);
            if isempty(packet_rx) || isempty(checksum) || ...
                    ~isequal(uint8(packet_rx(end-1:end)), uint8(checksum(:)))
                error('Packet %d failed demodulation or CRC check.', packet_idx);
            end
            packet_rx = uint8(packet_rx(1:end-2)); % Remove the two CRC bytes.
            decoded_idx = typecast(packet_rx(1:packet_index_bytes), 'uint32');
            if decoded_idx ~= packet_idx
                error('Packet order/index mismatch at packet %d.', packet_idx);
            end
            received_bytes = [received_bytes; packet_rx(packet_index_bytes+1:end)]; %#ok<AGROW>
        end

        received_audio = (double(received_bytes) - 127.5) / 127.5;
        audiowrite(output_audio, received_audio, saved.audio_sample_rate);
        fprintf('Reconstructed audio written to %s\n', output_audio);

    otherwise
        error('mode must be ''encode'' or ''decode''.');
end                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 
