% Fast airtime-only comparison for the audio packet format used by
% audiotest_timed.m and audio_rate_sweep.m. No PHY loopback is executed.

script_dir = fileparts(mfilename('fullpath'));
input_audio = fullfile(script_dir, '..', 'files', 'sample-3s.mp3');
result_dir = fullfile(script_dir, 'result');
if ~exist(result_dir, 'dir'), mkdir(result_dir); end
run_timestamp = char(datetime('now', 'Format', 'yyMMdd_HHmmss_SSS'));
result_csv = fullfile(result_dir, ['audio_airtime_results_' run_timestamp '.csv']);
result_mat = fullfile(result_dir, ['audio_airtime_results_' run_timestamp '.mat']);

sf_values = 7:12;
cr_values = 1:4;             % CR=1..4 correspond to 4/5..4/8.
bw_values = [125e3 250e3 500e3];
max_payload_bytes = 253;     % Application payload plus CRC fits decoder limit.
packet_index_bytes = 4;
audio_sample_rate = 8000;
has_header = 1;
crc = 1;
preamble_len = 8;

% Match audiotest_timed.m's mono 8 kHz, 8-bit PCM conversion and packet size.
[audio, source_fs] = audioread(input_audio);
audio = resample(mean(audio, 2), audio_sample_rate, source_fs);
audio_byte_count = numel(audio);
audio_duration = audio_byte_count / audio_sample_rate;
audio_bytes_per_packet = max_payload_bytes - packet_index_bytes;
packet_count = ceil(audio_byte_count / audio_bytes_per_packet);
packet_audio_bytes = min(audio_bytes_per_packet, ...
    audio_byte_count - (0:packet_count-1)' * audio_bytes_per_packet);
packet_lengths = packet_audio_bytes + packet_index_bytes;

scenario_count = numel(sf_values) * numel(cr_values) * numel(bw_values);
SF = zeros(scenario_count, 1);
CR = zeros(scenario_count, 1);
Bandwidth_kHz = zeros(scenario_count, 1);
PacketCount = repmat(packet_count, scenario_count, 1);
EstimatedAirtime_s = zeros(scenario_count, 1);
RadioGoodput_kbps = zeros(scenario_count, 1);
RealTimeFactor = zeros(scenario_count, 1);

% LoRaPHY.calc_sym_num() and LoRaPHY.time_on_air() equivalents.
% Computing these expressions avoids encode/modulate/demodulate/decode work.
row = 0;
for bw = bw_values
    for sf = sf_values
        for cr = cr_values
            row = row + 1;
            ldr = (2^sf / bw) > 16e-3;
            payload_symbols = 8 + max((4 + cr) .* ceil((2 .* packet_lengths ...
                - sf + 7 + 4 * crc - 5 * (1 - has_header)) ...
                ./ (sf - 2 * ldr)), 0);
            airtime_per_packet = (payload_symbols + 4.25 + preamble_len) ...
                .* (2^sf / bw);
            total_airtime = sum(airtime_per_packet);

            SF(row) = sf;
            CR(row) = cr;
            Bandwidth_kHz(row) = bw / 1e3;
            EstimatedAirtime_s(row) = total_airtime;
            RadioGoodput_kbps(row) = audio_byte_count * 8 / total_airtime / 1e3;
            RealTimeFactor(row) = total_airtime / audio_duration;
        end
    end
end

results = table(SF, CR, Bandwidth_kHz, PacketCount, EstimatedAirtime_s, ...
    RadioGoodput_kbps, RealTimeFactor);
writetable(results, result_csv);
save(result_mat, 'results', 'sf_values', 'cr_values', 'bw_values', ...
    'audio_byte_count', 'audio_duration', 'packet_lengths');

fprintf('Calculation only: no LoRa PHY loopback was run.\n');
fprintf('Audio data: %d bytes, %.2f s; %d packets (%d bytes audio + %d-byte index max).\n', ...
    audio_byte_count, audio_duration, packet_count, ...
    audio_bytes_per_packet, packet_index_bytes);
fprintf('Estimated airtime range across %d configurations: %.2f to %.2f seconds.\n', ...
    scenario_count, min(EstimatedAirtime_s), max(EstimatedAirtime_s));
fprintf('Results saved to:\n  %s\n  %s\n', result_csv, result_mat);

% Heatmaps make the SF/CR/BW airtime differences easy to compare.
figure('Name', 'Audio LoRa airtime calculation', 'Color', 'w');
tiledlayout(1, numel(bw_values), 'TileSpacing', 'compact');
for bw_idx = 1:numel(bw_values)
    bw = bw_values(bw_idx);
    airtime_grid = nan(numel(cr_values), numel(sf_values));
    for k = 1:height(results)
        if results.Bandwidth_kHz(k) == bw/1e3
            ri = find(cr_values == results.CR(k), 1);
            ci = find(sf_values == results.SF(k), 1);
            airtime_grid(ri, ci) = results.EstimatedAirtime_s(k);
        end
    end
    nexttile;
    imagesc(sf_values, cr_values, airtime_grid);
    set(gca, 'YDir', 'normal', 'XTick', sf_values, 'YTick', cr_values);
    xlabel('Spreading factor (SF)');
    ylabel('Code rate (4/(4+CR))');
    title(sprintf('Total airtime, BW %g kHz (s)', bw/1e3));
    colorbar;
end
