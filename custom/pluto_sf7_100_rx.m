% Receive and count numbered SF7 LoRaPHY packets, checking packet CRCs.
% Start this script first, then run pluto_sf7_100_tx.m on the TX Pluto.

script_dir = fileparts(mfilename('fullpath'));
addpath(fileparts(script_dir));

radio_id = 'usb:1';       % Set from findPlutoRadio on the RX computer.
rf_freq = 922.1e6;
sf = 7;
bw = 125e3;
fs = 1e6;
cr = 1;
expected_packets = 100;
payload_bytes = 16;
start_timeout_s = 180;    % Maximum wait for the first valid packet.
idle_timeout_s = 10;      % Allow RX/decoder time to drain the final packets.
buffer_seconds = 2;
process_interval_s = 0.5;
result_dir = fullfile(script_dir, 'result');
if ~exist(result_dir, 'dir'), mkdir(result_dir); end
run_timestamp = char(datetime('now', 'Format', 'yyMMdd_HHmmss_SSS'));
result_file = fullfile(result_dir, ...
    ['pluto_sf7_100_results_' run_timestamp '.csv']);

% Validate the ID in this MATLAB session before starting the listen loop.
available_radios = findPlutoRadio;
available_ids = {available_radios.RadioID};
if ~any(strcmp(radio_id, available_ids))
    if isempty(available_ids)
        available_text = '(none)';
    else
        available_text = strjoin(available_ids, ', ');
    end
    error('pluto_sf7_100_rx:RadioNotFound', ...
        ['RadioID "%s" is not visible in this MATLAB session. ' ...
        'findPlutoRadio reports: %s. Set radio_id to an available ID, ' ...
        'or release the radio from the other MATLAB session.'], ...
        radio_id, available_text);
end

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;
phy.cr = cr;
phy.crc = 1;
phy.preamble_len = 8;

rx = sdrrx('Pluto', ...
    'RadioID', radio_id, ...
    'CenterFrequency', rf_freq, ...
    'BasebandSampleRate', fs, ...
    'SamplesPerFrame', 65536, ...
    'OutputDataType', 'double', ...
    'GainSource', 'AGC Slow Attack');
rx_cleanup = onCleanup(@() release(rx));
[~, ~, initial_overflow] = rx(); % Force the hardware connection before reporting ready.
overflow_count = double(initial_overflow);
disp(info(rx));

received = false(expected_packets, 1);
rx_buffer = complex(zeros(0, 1));
max_buffer_samples = round(buffer_seconds * fs);
last_process_time = tic;
last_reported_count = 0;
last_valid_packet_time = [];
fprintf(['Listening at %.3f MHz, SF%d, BW %.0f kHz. Waiting up to %d s ' ...
    'for the first packet; will stop after %.1f s of packet inactivity.\n'], ...
    rf_freq/1e6, sf, bw/1e3, start_timeout_s, idle_timeout_s);
fprintf('Start pluto_sf7_100_tx.m now; receiver is ready.\n');

listen_timer = tic;
while toc(listen_timer) < start_timeout_s
    if ~isempty(last_valid_packet_time) && toc(last_valid_packet_time) >= idle_timeout_s
        fprintf('No new CRC-valid packet for %.1f s; ending reception.\n', ...
            idle_timeout_s);
        break;
    end

    [frame, ~, overflow] = rx();
    overflow_count = overflow_count + double(overflow);
    rx_buffer = [rx_buffer; double(frame(:))]; %#ok<AGROW>
    if numel(rx_buffer) > max_buffer_samples
        rx_buffer = rx_buffer(end-max_buffer_samples+1:end);
    end

    if toc(last_process_time) < process_interval_s
        continue;
    end
    last_process_time = tic;

    try
        demodulate_output = evalc('[symbols_rx, ~] = phy.demodulate(rx_buffer);'); %#ok<NASGU>
        if isempty(symbols_rx)
            continue;
        end
        [decoded, checksum] = phy.decode(symbols_rx);
    catch
        continue;
    end

    for col = 1:size(decoded, 2)
        if size(decoded, 1) < payload_bytes + 2 || isempty(checksum)
            continue;
        end
        payload = uint8(decoded(1:payload_bytes, col));
        received_crc = uint8(decoded(payload_bytes+1:payload_bytes+2, col));
        expected_crc = uint8(checksum(:, min(col, size(checksum, 2))));
        if ~isequal(received_crc(:), expected_crc(:)) || ...
                ~isequal(payload(1:3).', uint8('S7T'))
            continue;
        end

        packet_idx = 1 + double(payload(4)) + 256*double(payload(5));
        if packet_idx >= 1 && packet_idx <= expected_packets
            if ~received(packet_idx)
                received(packet_idx) = true;
                last_valid_packet_time = tic;
            end
        end
    end

    count = nnz(received);
    if count > last_reported_count
        fprintf('[CRC OK] %d/%d unique packets received\n', ...
            count, expected_packets);
        last_reported_count = count;
    end
    if count == expected_packets
        fprintf('All 100 packets received with valid CRC.\n');
        break;
    end
end

received_count = nnz(received);
missing_ids = find(~received).';
PRR_percent = 100 * received_count / expected_packets;
results = table(sf, bw/1e3, expected_packets, received_count, PRR_percent, ...
    overflow_count, string(strjoin(string(missing_ids), ';')), ...
    'VariableNames', {'SF', 'Bandwidth_kHz', 'Sent', 'CRC_OK', ...
    'PRR_percent', 'RX_overflow_reports', 'MissingPacketIDs'});
writetable(results, result_file);
disp(results);
fprintf('Saved results to %s\n', result_file);
release(rx);
