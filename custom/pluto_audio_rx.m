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
rx_start_timeout_s = 300; % Time allowed to start the transmitter.
rx_idle_timeout_s = 90;   % Wait after the last valid packet for trailing samples.

max_phy_payload_bytes = 253;
packet_index_bytes = 4;
packet_count_bytes = 4;
app_header_bytes = packet_index_bytes + packet_count_bytes;
file_size_bytes = 4;
data_bytes_per_packet = max_phy_payload_bytes - app_header_bytes - file_size_bytes;

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;
phy.cr = 1;         % Coding rate 4/5.
phy.crc = 1;
phy.preamble_len = 8;
phy.fast_mode = true; % Skip the input low-pass filter to reduce processing time.

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
fprintf('RX mode: partial-save build; idle timeout %d s.\n', rx_idle_timeout_s);

% Discard initial transient samples before asking the user to start TX.
rx();
rx();

fprintf('Listening on Pluto RadioID %s at %.3f MHz. Start the TX script now.\n', ...
    radio_id, rf_freq/1e6);

rx_buffer = complex(zeros(0, 1));
samples_since_demod = 0;
demod_retry_samples = 4 * rx_frame_samples;
packet_total = [];
received_chunks = {};
last_packet_time = tic;
listen_start_time = tic;
transfer_started = false;
rx_overflow_count = 0;

while true
    if transfer_started
        if toc(last_packet_time) >= rx_idle_timeout_s
            break;
        end
    elseif toc(listen_start_time) >= rx_start_timeout_s
        break;
    end

    [rx_frame, ~, rx_overflow] = rx();
    rx_overflow_count = rx_overflow_count + double(rx_overflow);
    rx_buffer = [rx_buffer; double(rx_frame(:))]; %#ok<AGROW>
    samples_since_demod = samples_since_demod + numel(rx_frame);

    % Wait until the buffer can contain a complete packet plus one RX frame.
    if numel(rx_buffer) < max_packet_samples + rx_frame_samples || ...
            samples_since_demod < demod_retry_samples
        continue;
    end
    samples_since_demod = 0;

    try
        % Hide the expected warning during idle periods.
        demodulate_output = evalc('[rx_symbols, ~] = phy.demodulate(rx_buffer);'); %#ok<NASGU>
    catch
        % Ignore incomplete or noise-only windows and keep listening.
        rx_symbols = [];
    end

    if isempty(rx_symbols)
        if numel(rx_buffer) > max_packet_samples
            rx_buffer = rx_buffer(end-max_packet_samples+1:end);
        end
        continue;
    end

    for col = 1:size(rx_symbols, 2)
        % Decode candidates separately so CRC-disabled noise candidates cannot
        % misalign the checksum columns or stop the receiver.
        try
            [decoded_packet, packet_checksum] = phy.decode(rx_symbols(:, col));
        catch
            continue;
        end
        if isempty(decoded_packet) || isempty(packet_checksum)
            continue;
        end

        decoded = uint8(decoded_packet(:, 1));
        checksum = uint8(packet_checksum(:, 1));
        if numel(decoded) < app_header_bytes + 2 || ...
                ~isequal(decoded(end-1:end), checksum(:))
            continue;
        end

        app_data = decoded(1:end-2); % Exclude the two CRC bytes.
        packet_idx = double(typecast(app_data(1:packet_index_bytes).', 'uint32'));
        this_total = double(typecast(app_data(packet_index_bytes+1:app_header_bytes).', 'uint32'));
        file_size_end = app_header_bytes + file_size_bytes;
        if numel(app_data) < file_size_end
            continue;
        end
        this_file_size = double(typecast(app_data(app_header_bytes+1:file_size_end).', 'uint32'));
        if this_total < 1 || packet_idx < 1 || packet_idx > this_total || ...
                this_file_size < 1 || ceil(this_file_size/data_bytes_per_packet) ~= this_total
            continue;
        end

        if isempty(packet_total)
            packet_total = this_total;
            received_chunks = cell(packet_total, 1);
            expected_file_size = this_file_size;
            transfer_started = true;
            fprintf('Transfer has %d packets.\n', packet_total);
        elseif this_total ~= packet_total || this_file_size ~= expected_file_size
            continue;
        end

        last_packet_time = tic;
        if isempty(received_chunks{packet_idx})
            received_chunks{packet_idx} = app_data(file_size_end+1:end);
            fprintf('Received packet %d/%d (CRC passed)\n', packet_idx, packet_total);
        end
    end

    % TX sends one packet per frame with an explicit silent gap.
    rx_buffer = complex(zeros(0, 1));
    samples_since_demod = 0;
    if transfer_started && all(~cellfun(@isempty, received_chunks))
        break;
    end
end

release(rx);
fprintf('Receiver overflow reports: %d\n', rx_overflow_count);

if isempty(packet_total)
    error('No valid LoRa packet received before timeout.');
end
missing_packets = find(cellfun(@isempty, received_chunks));
if ~isempty(missing_packets)
    fprintf('Transfer ended with %d missing packet(s): %s\n', ...
        numel(missing_packets), mat2str(missing_packets(1:min(20, end))'));
    for missing_idx = missing_packets(:)'
        chunk_start = (missing_idx - 1) * data_bytes_per_packet + 1;
        chunk_length = min(data_bytes_per_packet, expected_file_size - chunk_start + 1);
        if chunk_length > 0
            received_chunks{missing_idx} = zeros(chunk_length, 1, 'uint8');
        else
            received_chunks{missing_idx} = zeros(0, 1, 'uint8');
        end
    end
end

received_file_bytes = vertcat(received_chunks{:});
if numel(received_file_bytes) ~= expected_file_size
    error('Reassembled size mismatch: expected %d bytes, got %d bytes.', ...
        expected_file_size, numel(received_file_bytes));
end
fid = fopen(output_file, 'wb');
if fid < 0
    error('Cannot create output file: %s', output_file);
end
fwrite(fid, received_file_bytes, 'uint8');
fclose(fid);
if isempty(missing_packets)
    fprintf('Reassembled MP3 saved to %s (%d bytes).\n', ...
        output_file, numel(received_file_bytes));
else
    fprintf('Partial MP3 saved to %s (%d bytes; missing chunks zero-filled).\n', ...
        output_file, numel(received_file_bytes));
end
