% Receive MP3 bytes sent by pluto_audio_tx.m using one PlutoSDR.
% Run this in a second MATLAB session and start it before the transmitter.

script_dir = fileparts(mfilename('fullpath'));
addpath(fileparts(script_dir));

output_file = fullfile(script_dir, 'audio_received.mp3');
radio_id = 'usb:1'; % Confirm with findPlutoRadio in this MATLAB session.
rf_freq = 915e6;    % Match the configured Pluto center frequency.
sf = 7;
bw = 125e3;
fs = 1e6;
rx_frame_samples = 65536;
rx_timeout_s = 300;

max_phy_payload_bytes = 253;
packet_index_bytes = 4;
packet_count_bytes = 4;
app_header_bytes = packet_index_bytes + packet_count_bytes;

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;
phy.cr = 1;         % Coding rate 4/5.
phy.crc = 1;
phy.preamble_len = 8;

probe_symbols = phy.encode(zeros(max_phy_payload_bytes, 1, 'uint8'));
probe_signal = phy.modulate(probe_symbols);
max_packet_samples = numel(probe_signal);
clear probe_symbols probe_signal;

rx = sdrrx('Pluto', ...
    'RadioID', radio_id, ...
    'CenterFrequency', rf_freq, ...
    'BasebandSampleRate', fs, ...
    'SamplesPerFrame', rx_frame_samples, ...
    'OutputDataType', 'double', ...
    'GainSource', 'AGC Slow Attack');
rx_cleanup = onCleanup(@() release(rx));
disp(info(rx));

fprintf('Listening on Pluto RadioID %s at %.3f MHz. Start the TX script now.\n', ...
    radio_id, rf_freq/1e6);

rx_buffer = complex(zeros(0, 1));
packet_total = [];
received_chunks = {};
last_packet_time = tic;
transfer_started = false;

while toc(last_packet_time) < rx_timeout_s
    rx_frame = rx();
    rx_buffer = [rx_buffer; double(rx_frame(:))]; %#ok<AGROW>

    % Wait until the buffer can contain a complete packet plus one RX frame.
    if numel(rx_buffer) < max_packet_samples + rx_frame_samples
        continue;
    end

    try
        [rx_symbols, ~] = phy.demodulate(rx_buffer);
    catch
        % Ignore incomplete or noise-only windows and keep listening.
        rx_symbols = [];
    end

    if isempty(rx_symbols)
        if numel(rx_buffer) > 3 * max_packet_samples
            rx_buffer = rx_buffer(end-3*max_packet_samples+1:end);
        end
        continue;
    end

    try
        [decoded_packets, checksums] = phy.decode(rx_symbols);
    catch
        rx_buffer = rx_buffer(end-min(numel(rx_buffer), max_packet_samples)+1:end);
        continue;
    end

    for col = 1:size(decoded_packets, 2)
        decoded = uint8(decoded_packets(:, col));
        checksum = uint8(checksums(:, min(col, size(checksums, 2))));
        if numel(decoded) < app_header_bytes + 2 || ...
                ~isequal(decoded(end-1:end), checksum(:))
            continue;
        end

        app_data = decoded(1:end-2); % Exclude the two CRC bytes.
        packet_idx = double(typecast(app_data(1:packet_index_bytes).', 'uint32'));
        this_total = double(typecast(app_data(packet_index_bytes+1:app_header_bytes).', 'uint32'));
        if this_total < 1 || packet_idx < 1 || packet_idx > this_total
            continue;
        end

        if isempty(packet_total)
            packet_total = this_total;
            received_chunks = cell(packet_total, 1);
            transfer_started = true;
            fprintf('Transfer has %d packets.\n', packet_total);
        elseif this_total ~= packet_total
            continue;
        end

        if isempty(received_chunks{packet_idx})
            received_chunks{packet_idx} = app_data(app_header_bytes+1:end);
            last_packet_time = tic;
            fprintf('Received packet %d/%d (CRC passed)\n', packet_idx, packet_total);
        end
    end

    % TX sends one packet per frame with an explicit silent gap.
    rx_buffer = complex(zeros(0, 1));
    if transfer_started && all(~cellfun(@isempty, received_chunks))
        break;
    end
end

release(rx);

if isempty(packet_total)
    error('No valid LoRa packet received before timeout.');
end
missing_packets = find(cellfun(@isempty, received_chunks));
if ~isempty(missing_packets)
    error('Transfer incomplete; missing %d packet(s). First missing indices: %s', ...
        numel(missing_packets), mat2str(missing_packets(1:min(20, end))'));
end

received_file_bytes = vertcat(received_chunks{:});
fid = fopen(output_file, 'wb');
if fid < 0
    error('Cannot create output file: %s', output_file);
end
fwrite(fid, received_file_bytes, 'uint8');
fclose(fid);
fprintf('Reassembled MP3 saved to %s (%d bytes).\n', ...
    output_file, numel(received_file_bytes));
