% RF parameter sweep receiver for a two-PlutoSDR LoRaPHY link.
% Start this script first, then run pluto_sweep_tx.m on the TX Pluto.
% Capture IQ without decoding to avoid overruns; decode the capture offline.

script_dir = fileparts(mfilename('fullpath'));
addpath(fileparts(script_dir));

radio_id = 'usb:1';       % Set from findPlutoRadio on the RX computer.
rf_freq = 922.1e6;
sf_list = [7 8 9 10];     % Keep in sync with pluto_sweep_tx.m.
bw = 125e3;
fs = 1e6;                 % Keep in sync with pluto_sweep_tx.m.
cr = 1;
repeat_count = 100;         % Expected packets per SF, from the TX script.
payload_bytes = 16;
rx_frame_samples = 65536;
capture_seconds = 360;     % Start TX as soon as RX reports ready.
capture_dtype = 'single'; % Reduce memory while capturing raw IQ.
decode_window_s = 4;
decode_step_s = 2;         % Overlap windows so packets at boundaries are retained.
result_file = fullfile(script_dir, 'pluto_sweep_results.csv');

available_radios = findPlutoRadio;
available_ids = {available_radios.RadioID};
if ~any(strcmp(radio_id, available_ids))
    if isempty(available_ids)
        available_text = '(none)';
    else
        available_text = strjoin(available_ids, ', ');
    end
    error('pluto_sweep_rx:RadioNotFound', ...
        ['RadioID "%s" is not visible in this MATLAB session. ' ...
        'findPlutoRadio reports: %s. Set radio_id to an available ID, ' ...
        'or release the radio from the other MATLAB session.'], ...
        radio_id, available_text);
end

rx = sdrrx('Pluto', ...
    'RadioID', radio_id, ...
    'CenterFrequency', rf_freq, ...
    'BasebandSampleRate', fs, ...
    'SamplesPerFrame', rx_frame_samples, ...
    'OutputDataType', capture_dtype, ...
    'GainSource', 'AGC Slow Attack');
rx_cleanup = onCleanup(@() release(rx));
[~, ~, initial_overflow] = rx(); % Confirm connection before reporting ready.
overflow_count = double(initial_overflow);
disp(info(rx));

case_count = numel(sf_list);
received = false(case_count, repeat_count);
rx_capture = complex(zeros(ceil(capture_seconds*fs/rx_frame_samples) * ...
    rx_frame_samples, 1, capture_dtype));
write_idx = 1;
fprintf(['Capturing %.0f s at %.3f MHz, BW %.0f kHz. ' ...
    'Start pluto_sweep_tx.m now. Decoding runs after capture.\n'], ...
    capture_seconds, rf_freq/1e6, bw/1e3);

capture_timer = tic;
while toc(capture_timer) < capture_seconds
    [frame, ~, overflow] = rx();
    overflow_count = overflow_count + double(overflow);
    sample_count = numel(frame);
    if write_idx + sample_count - 1 > numel(rx_capture)
        % Grow in whole frames only if the loop runs slightly past its target.
        rx_capture(end+rx_frame_samples, 1) = complex(single(0));
    end
    rx_capture(write_idx:write_idx+sample_count-1) = frame(:);
    write_idx = write_idx + sample_count;
end
rx_capture = rx_capture(1:write_idx-1);
release(rx);
fprintf('IQ capture complete: %.2f s, RX overflow reports: %d. Decoding offline...\n', ...
    numel(rx_capture)/fs, overflow_count);

phy_candidates = cell(case_count, 1);
for case_idx = 1:case_count
    phy_candidates{case_idx} = LoRaPHY(rf_freq, sf_list(case_idx), bw, fs);
    phy_candidates{case_idx}.has_header = 1;
    phy_candidates{case_idx}.cr = cr;
    phy_candidates{case_idx}.crc = 1;
    phy_candidates{case_idx}.preamble_len = 8;
end

window_samples = round(decode_window_s * fs);
step_samples = round(decode_step_s * fs);
last_start = max(1, numel(rx_capture) - window_samples + 1);
window_starts = 1:step_samples:last_start;
if isempty(window_starts) || window_starts(end) ~= last_start
    window_starts(end+1) = last_start;
end

for window_idx = 1:numel(window_starts)
    first_sample = window_starts(window_idx);
    last_sample = min(first_sample + window_samples - 1, numel(rx_capture));
    if last_sample - first_sample + 1 < window_samples
        continue;
    end
    rx_window = double(rx_capture(first_sample:last_sample));

    for case_idx = 1:case_count
        sf = sf_list(case_idx);
        phy = phy_candidates{case_idx};
        try
            demodulate_output = evalc('[symbols_rx, ~] = phy.demodulate(rx_window);'); %#ok<NASGU>
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
                    ~isequal(payload(1:3).', uint8('SWP')) || ...
                    double(payload(4)) ~= case_idx
                continue;
            end

            packet_idx = double(payload(5));
            if packet_idx >= 1 && packet_idx <= repeat_count && ...
                    ~received(case_idx, packet_idx)
                received(case_idx, packet_idx) = true;
                fprintf('[CRC OK] SF%d packet %d/%d\n', ...
                    sf, packet_idx, repeat_count);
            end
        end
    end
end

SF = sf_list(:);
Bandwidth_kHz = repmat(bw/1e3, case_count, 1);
Sent = repmat(repeat_count, case_count, 1);
CRC_OK = sum(received, 2);
PRR_percent = 100 * CRC_OK ./ Sent;
RX_overflow_reports = repmat(overflow_count, case_count, 1);
results = table(SF, Bandwidth_kHz, Sent, CRC_OK, PRR_percent, RX_overflow_reports);
writetable(results, result_file);
disp(results);
fprintf('Saved sweep results to %s\n', result_file);
