% Receive UTF-8 text messages sent by pluto_text_tx.m using PlutoSDR.
% Start this script before starting the transmitter.

script_dir = fileparts(mfilename('fullpath'));
addpath(fileparts(script_dir));

radio_id = 'usb:1';       % Change to the ID reported by findPlutoRadio.
rf_freq = 922.1e6;        % KR920-923 default LoRaWAN channel; match TX.
sf = 7;
bw = 125e3;
fs = 1e6;
rx_frame_samples = 65536;
listen_seconds = 60;

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;
phy.cr = 1;                % Coding rate 4/5.
phy.crc = 1;
phy.preamble_len = 8;

rx = sdrrx('Pluto', ...
    'RadioID', radio_id, ...
    'CenterFrequency', rf_freq, ...
    'BasebandSampleRate', fs, ...
    'SamplesPerFrame', rx_frame_samples, ...
    'OutputDataType', 'double', ...
    'GainSource', 'AGC Slow Attack');
rx_cleanup = onCleanup(@() release(rx));
disp(info(rx));

fprintf('Listening on Pluto RadioID %s at %.3f MHz for %d seconds.\n', ...
    radio_id, rf_freq/1e6, listen_seconds);
fprintf('Run pluto_text_tx.m on the other PlutoSDR.\n');

rx_buffer = complex(zeros(0, 1));
timer = tic;
while toc(timer) < listen_seconds
    frame = rx();
    rx_buffer = [rx_buffer; double(frame(:))]; %#ok<AGROW>

    % Keep enough samples for a packet spanning several RX frames.
    if numel(rx_buffer) < 3*rx_frame_samples
        continue;
    end

    try
        % demodulate warns on every idle window; capture that expected output.
        demodulate_output = evalc('[rx_symbols, ~] = phy.demodulate(rx_buffer);'); %#ok<NASGU>
    catch
        rx_symbols = [];
    end

    if isempty(rx_symbols)
        % Retain a tail so a packet crossing the next frame boundary is kept.
        keep = min(numel(rx_buffer), 2*rx_frame_samples);
        rx_buffer = rx_buffer(end-keep+1:end);
        continue;
    end

    try
        [decoded, checksum] = phy.decode(rx_symbols);
    catch
        decoded = [];
        checksum = [];
    end

    for col = 1:size(decoded, 2)
        payload_len = phy.payload_len;
        if payload_len < 1 || size(decoded, 1) < payload_len + 2 || isempty(checksum)
            continue;
        end
        received_payload = uint8(decoded(1:payload_len, col));
        received_crc = uint8(decoded(payload_len+1:payload_len+2, col));
        expected_crc = uint8(checksum(:, min(col, size(checksum, 2))));
        if ~isequal(received_crc(:), expected_crc(:))
            fprintf('Detected packet but CRC failed.\n');
            continue;
        end

        message = native2unicode(received_payload(:).', 'UTF-8');
        fprintf('[CRC OK] Received text: %s\n', message);
    end

    % Allow detection of repeated packets while avoiding re-decoding old samples.
    keep = min(numel(rx_buffer), 2*rx_frame_samples);
    rx_buffer = rx_buffer(end-keep+1:end);
end

release(rx);
fprintf('Listening complete.\n');
