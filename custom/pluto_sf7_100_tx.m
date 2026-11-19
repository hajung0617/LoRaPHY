% Send 100 numbered SF7 LoRaPHY packets through PlutoSDR.
% Start pluto_sf7_100_rx.m on the receiving Pluto before running this script.

script_dir = fileparts(mfilename('fullpath'));
addpath(fileparts(script_dir));

radio_id = 'sn:1044739a470b000e17001f00235f7efe51'; % TX Pluto serial number.
rf_freq = 263e6;
sf = 7;
bw = 125e3;
fs = 1e6;
cr = 1;                   % LoRaPHY coding-rate index 1 means 4/5.
repeat_count = 100;
gap_s = 0.25;
tx_gain = -50;
payload_bytes = 16;

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;
phy.cr = cr;
phy.crc = 1;
phy.preamble_len = 8;

% Every packet uses the same fixed frame length so the Pluto TX object can
% stay configured for the entire run.
probe_payload = makePayload(1, payload_bytes);
probe_signal = phy.modulate(phy.encode(probe_payload(:)));
frame_length = numel(probe_signal) + round(gap_s*fs);

tx = sdrtx('Pluto', ...
    'RadioID', radio_id, ...
    'CenterFrequency', rf_freq, ...
    'BasebandSampleRate', fs, ...
    'Gain', tx_gain);
tx_cleanup = onCleanup(@() release(tx));
disp(info(tx));

fprintf('SF%d, BW %.0f kHz, CR 4/5, %d numbered packets at %.3f MHz.\n', ...
    sf, bw/1e3, repeat_count, rf_freq/1e6);
fprintf('Make sure pluto_sf7_100_rx.m is listening, then press Enter.\n');
pause;

underflow_count = 0;
for packet_idx = 1:repeat_count
    payload = makePayload(packet_idx, payload_bytes);
    signal = phy.modulate(phy.encode(payload(:)));
    frame = complex(zeros(frame_length, 1));
    frame(1:numel(signal)) = signal(:);

    peak = max(abs(frame));
    if peak > 0
        frame = 0.7 * frame / peak;
    end

    underflow = tx(frame);
    % Ignore the first call's initialization transient; count later losses.
    if packet_idx > 1
        underflow_count = underflow_count + double(underflow);
    end
    if mod(packet_idx, 10) == 0 || packet_idx == 1
        fprintf('Sent %d/%d packets\n', packet_idx, repeat_count);
    end
end

% Send a final silent frame so the last packet is followed by a drain interval.
tail_underflow = tx(complex(zeros(frame_length, 1)));
underflow_count = underflow_count + double(tail_underflow);
pause(0.5);
release(tx);
fprintf('100-packet SF7 transmission complete. TX underflow reports: %d\n', ...
    underflow_count);

function payload = makePayload(packet_idx, payload_bytes)
% Payload: 3-byte marker, little-endian uint16 sequence, fixed-size padding.
payload = [uint8('S7T'), ...
    uint8(mod(packet_idx-1, 256)), ...
    uint8(floor((packet_idx-1)/256)), ...
    zeros(1, payload_bytes-5, 'uint8')];
end
