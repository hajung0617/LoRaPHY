% Compare audio LoRa throughput for every SF/CR/BW combination.
% This is a software loopback: simulated radio goodput comes from LoRa
% time-on-air, while MATLAB processing rate is measured separately.

script_dir = fileparts(mfilename('fullpath'));
project_dir = fileparts(fileparts(script_dir));
addpath(project_dir);

input_audio = fullfile(fileparts(fileparts(script_dir)), 'data', 'experiments', 'audio', 'sample-3s.mp3');
result_dir = fullfile(fileparts(fileparts(script_dir)), 'experiments', 'results', 'audio');
if ~exist(result_dir, 'dir'), mkdir(result_dir); end
run_timestamp = char(datetime('now', 'Format', 'yyMMdd_HHmmss_SSS'));
result_csv = fullfile(result_dir, ['audio_rate_sweep_results_' run_timestamp '.csv']);
result_mat = fullfile(result_dir, ['audio_rate_sweep_results_' run_timestamp '.mat']);

rf_freq = 470e6; % Required by LoRaPHY constructor; software loopback uses no RF.
sf_values = 7:12;
cr_values = 1:4;
bw_values = [125e3 250e3 500e3];
fs = 1e6;
has_header = 1;
crc = 1;
preamble_len = 8;
max_payload_bytes = 253; % Decoder limit includes the two CRC bytes.
packet_index_bytes = 4;
audio_sample_rate = 8000;

% Use the same mono 8 kHz, 8-bit PCM input and packet payload sizing as
% audiotest_timed.m. Preprocessing is excluded from PHY processing timing.
[audio, source_fs] = audioread(input_audio);
audio = resample(mean(audio, 2), audio_sample_rate, source_fs);
audio_bytes = uint8(round(max(-1, min(1, audio)) * 127.5 + 127.5));
audio_byte_count = numel(audio_bytes);
audio_duration = audio_byte_count / audio_sample_rate;
audio_bytes_per_packet = max_payload_bytes - packet_index_bytes;
packet_count = ceil(audio_byte_count / audio_bytes_per_packet);

scenario_count = numel(sf_values) * numel(cr_values) * numel(bw_values);
SF = zeros(scenario_count, 1);
CR = zeros(scenario_count, 1);
Bandwidth_kHz = zeros(scenario_count, 1);
PacketCount = repmat(packet_count, scenario_count, 1);
EstimatedAirtime_s = zeros(scenario_count, 1);
RadioGoodput_kbps = zeros(scenario_count, 1);
MeasuredPHYTime_s = zeros(scenario_count, 1);
MeasuredPHYRate_kbps = zeros(scenario_count, 1);
RealTimeFactor = zeros(scenario_count, 1);

fprintf('Audio: %d bytes, %.2f s; %d packets; sweeping %d configurations.\n', ...
    audio_byte_count, audio_duration, packet_count, scenario_count);
row = 0;
for bw_idx = 1:numel(bw_values)
    for sf_idx = 1:numel(sf_values)
        for cr_idx = 1:numel(cr_values)
            row = row + 1;
            sf = sf_values(sf_idx);
            cr = cr_values(cr_idx);
            bw = bw_values(bw_idx);

            phy = LoRaPHY(rf_freq, sf, bw, fs);
            phy.has_header = has_header;
            phy.cr = cr;
            phy.crc = crc;
            phy.preamble_len = preamble_len;

            airtime_s = 0;
            processing_timer = tic;
            for packet_idx = 1:packet_count
                first = (packet_idx - 1) * audio_bytes_per_packet + 1;
                last = min(packet_idx * audio_bytes_per_packet, audio_byte_count);
                packet_payload = [typecast(uint32(packet_idx), 'uint8')'; ...
                    audio_bytes(first:last)];

                % Calculate actual packet airtime using LoRaPHY's symbol count.
                airtime_s = airtime_s + phy.time_on_air(numel(packet_payload)) / 1000;

                tx_symbols = phy.encode(packet_payload);
                tx_signal = phy.modulate(tx_symbols);
                [rx_symbols, ~] = phy.demodulate(tx_signal);
                [rx_payload, crc_value] = phy.decode(rx_symbols);
                if isempty(rx_payload) || isempty(crc_value) || ...
                        ~isequal(uint8(rx_payload(end-1:end)), uint8(crc_value(:)))
                    error('Loopback failed for SF%d CR4/%d BW%d kHz, packet %d.', ...
                        sf, cr+4, bw/1e3, packet_idx);
                end
                rx_payload = uint8(rx_payload(1:end-2));
                rx_packet_idx = typecast(rx_payload(1:packet_index_bytes), 'uint32');
                expected_payload = [typecast(uint32(packet_idx), 'uint8')'; ...
                    audio_bytes(first:last)];
                if rx_packet_idx ~= packet_idx || ...
                        ~isequal(rx_payload, expected_payload)
                    error('Payload mismatch for SF%d CR4/%d BW%d kHz, packet %d.', ...
                        sf, cr+4, bw/1e3, packet_idx);
                end
            end
            processing_s = toc(processing_timer);

            SF(row) = sf;
            CR(row) = cr;
            Bandwidth_kHz(row) = bw / 1e3;
            EstimatedAirtime_s(row) = airtime_s;
            RadioGoodput_kbps(row) = audio_byte_count * 8 / airtime_s / 1e3;
            MeasuredPHYTime_s(row) = processing_s;
            MeasuredPHYRate_kbps(row) = audio_byte_count * 8 / processing_s / 1e3;
            RealTimeFactor(row) = processing_s / audio_duration;

            fprintf('[%2d/%2d] SF%d CR4/%d BW%d kHz: airtime %.2f s, radio %.2f kb/s, MATLAB %.2f s\n', ...
                row, scenario_count, sf, cr+4, bw/1e3, airtime_s, ...
                RadioGoodput_kbps(row), processing_s);
        end
    end
end

results = table(SF, CR, Bandwidth_kHz, PacketCount, EstimatedAirtime_s, ...
    RadioGoodput_kbps, MeasuredPHYTime_s, MeasuredPHYRate_kbps, RealTimeFactor);
writetable(results, result_csv);
save(result_mat, 'results', 'sf_values', 'cr_values', 'bw_values', ...
    'audio_byte_count', 'audio_duration');

% Each heatmap compares all SF/CR pairs at one bandwidth.
figure('Name', 'LoRa audio rate sweep', 'Color', 'w');
tiledlayout(2, numel(bw_values), 'TileSpacing', 'compact');
for bw_idx = 1:numel(bw_values)
    bw = bw_values(bw_idx);
    radio_grid = nan(numel(cr_values), numel(sf_values));
    phy_grid = radio_grid;
    for k = 1:height(results)
        if results.Bandwidth_kHz(k) == bw/1e3
            ri = find(cr_values == results.CR(k), 1);
            ci = find(sf_values == results.SF(k), 1);
            radio_grid(ri, ci) = results.RadioGoodput_kbps(k);
            phy_grid(ri, ci) = results.MeasuredPHYRate_kbps(k);
        end
    end

    nexttile(bw_idx);
    imagesc(sf_values, cr_values, radio_grid);
    set(gca, 'YDir', 'normal', 'XTick', sf_values, 'YTick', cr_values);
    xlabel('Spreading factor (SF)'); ylabel('Code rate (4/(4+CR))');
    title(sprintf('Radio goodput, BW %g kHz (kb/s)', bw/1e3));
    colorbar;

    nexttile(numel(bw_values) + bw_idx);
    imagesc(sf_values, cr_values, phy_grid);
    set(gca, 'YDir', 'normal', 'XTick', sf_values, 'YTick', cr_values);
    xlabel('Spreading factor (SF)'); ylabel('Code rate (4/(4+CR))');
    title(sprintf('Measured MATLAB PHY rate, BW %g kHz (kb/s)', bw/1e3));
    colorbar;
end

fprintf('\nResults saved to:\n  %s\n  %s\n', result_csv, result_mat);
fprintf('Radio goodput reflects estimated on-air time. MATLAB PHY rate is a separate software timing measurement.\n');
