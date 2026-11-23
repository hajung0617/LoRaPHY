% Transmit a LoRaPHY-generated test packet through PlutoSDR.
% Pair with pluto_sx1280_rx.m to check BW=203.125 kHz over RF.

script_dir = fileparts(mfilename('fullpath'));
project_dir = fileparts(fileparts(script_dir));
addpath(project_dir);

radio_id = 'usb:1';       % Set to the TX Pluto ID from findPlutoRadio.
rf_freq = 2.4e9;          % Must match the receiver and use a locally permitted channel.
sf = 7;
bw = 203.125e3;
fs = 4 * bw;              % 812.5 kS/s: exactly 512 samples per SF7 symbol.
tx_gain = -30;
repeat_count = 5;
gap_s = 0.5;

message = input('Test text to transmit: ', 's');
if isempty(message)
    error('Enter a non-empty message.');
end
payload = uint8(unicode2native(message, 'UTF-8'));
if numel(payload) > 255
    error('LoRaPHY supports at most 255 payload bytes.');
end

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;
phy.cr = 1;                % CR 4/5.
phy.crc = 1;
phy.preamble_len = 8;

symbols = phy.encode(payload(:));
signal = phy.modulate(symbols);
frame = [signal(:); complex(zeros(round(gap_s * fs), 1))];
peak = max(abs(frame));
if peak > 0
    frame = 0.7 * frame / peak;
end

fprintf('LoRaPHY Pluto TX: %s (%d UTF-8 bytes), %.3f MHz, SF%d, BW %.3f kHz.\n', ...
    message, numel(payload), rf_freq/1e6, sf, bw/1e3);
fprintf('Start pluto_sx1280_rx.m on the other Pluto, then press Enter.\n');
pause;

tx = sdrtx('Pluto', ...
    'RadioID', radio_id, ...
    'CenterFrequency', rf_freq, ...
    'BasebandSampleRate', fs, ...
    'Gain', tx_gain);
tx_cleanup = onCleanup(@() release(tx));
disp(info(tx));

for k = 1:repeat_count
    tx(frame);
    fprintf('Sent test packet %d/%d\n', k, repeat_count);
end
release(tx);
fprintf('Pluto test transmission complete.\n');
