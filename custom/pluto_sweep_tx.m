% RF parameter sweep transmitter for a two-PlutoSDR LoRaPHY link.
% Start pluto_sweep_rx.m first, then run this script on the TX Pluto.
% This first sweep varies SF only; RF frequency, BW, CR, and payload stay fixed.

script_dir = fileparts(mfilename('fullpath'));
addpath(fileparts(script_dir));

radio_id = 'usb:0';       % Set from findPlutoRadio on the TX computer.
rf_freq = 922.1e6;
sf_list = [7 8 9 10];
bw = 125e3;
fs = 1e6;                 % Shared with RX; sufficient for BW=125 kHz.
cr = 1;                   % LoRaPHY coding-rate index 1 means 4/5.
repeat_count = 100;
gap_s = 0.25;
tx_gain = -30;
payload_bytes = 16;

available_radios = findPlutoRadio;
available_ids = {available_radios.RadioID};
if ~any(strcmp(radio_id, available_ids))
    if isempty(available_ids)
        available_text = '(none)';
    else
        available_text = strjoin(available_ids, ', ');
    end
    error('pluto_sweep_tx:RadioNotFound', ...
        'RadioID "%s" is not visible here. findPlutoRadio reports: %s.', ...
        radio_id, available_text);
end

tx = sdrtx('Pluto', ...
    'RadioID', radio_id, ...
    'CenterFrequency', rf_freq, ...
    'BasebandSampleRate', fs, ...
    'Gain', tx_gain);
tx_cleanup = onCleanup(@() release(tx));
disp(info(tx));

fprintf('SF sweep at %.3f MHz, BW %.0f kHz, CR 4/5; %d packets per SF.\n', ...
    rf_freq/1e6, bw/1e3, repeat_count);
fprintf('Make sure pluto_sweep_rx.m is listening, then press Enter.\n');
pause;

total_underflow_count = 0;
for case_idx = 1:numel(sf_list)
    % Packet length changes with SF; unlock the System object between cases.
    if case_idx > 1
        release(tx);
    end
    sf = sf_list(case_idx);
    phy = LoRaPHY(rf_freq, sf, bw, fs);
    phy.has_header = 1;
    phy.cr = cr;
    phy.crc = 1;
    phy.preamble_len = 8;
    case_underflow_count = 0;

    for packet_idx = 1:repeat_count
        % Payload layout: "SWP", sweep case index, packet index, padding.
        payload = [uint8('SWP'), uint8(case_idx), uint8(packet_idx), ...
            zeros(1, payload_bytes-5, 'uint8')];
        symbols = phy.encode(payload(:));
        signal = phy.modulate(symbols);

        frame = complex(zeros(numel(signal) + round(gap_s*fs), 1));
        frame(1:numel(signal)) = signal(:);
        peak = max(abs(frame));
        if peak > 0
            frame = 0.7 * frame / peak;
        end

        underflow = tx(frame);
        % The first call after initialization/release can report a transient.
        if packet_idx > 1
            case_underflow_count = case_underflow_count + double(underflow);
        end
        fprintf('Sent SF%d packet %d/%d\n', sf, packet_idx, repeat_count);
    end

    % Drain the final packet with one same-size silent frame before release.
    tail_underflow = tx(complex(zeros(size(frame))));
    case_underflow_count = case_underflow_count + double(tail_underflow);
    total_underflow_count = total_underflow_count + case_underflow_count;
    fprintf('SF%d TX underflow reports: %d\n', sf, case_underflow_count);
    pause(0.5); % Give RX a clear gap before the next SF case.
end

release(tx);
fprintf('Sweep transmission complete. Total TX underflow reports: %d\n', ...
    total_underflow_count);
