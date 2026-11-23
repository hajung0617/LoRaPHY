
%% =========================================================
%  Kookmin University 3D Building Model
%  OSM + Building Register + Existing Matching CSV
% =========================================================

clear; clc; close all;

%% 1. 경로 설정

rootDir = fileparts(fileparts(mfilename("fullpath")));

osmFile = fullfile(rootDir, "data", "simulation", "raw", "map.osm");

registerFile = fullfile(rootDir, ...
    "data", "simulation", "raw", "03. 표제부_20261116151251.csv");

matchFile = fullfile(rootDir, ...
    "data", "simulation", "processed", ...
    "building_height_matching_v2.csv");

outputDir = fullfile(rootDir, "simulation", "results", "building_updates");

if ~isfolder(outputDir)
    mkdir(outputDir);
end

assert(isfile(osmFile), "OSM 파일이 없습니다.");
assert(isfile(registerFile), "표제부 CSV가 없습니다.");
assert(isfile(matchFile), "매칭 CSV가 없습니다.");

%% 2. 데이터 불러오기

buildings = readgeotable(osmFile, ...
    Layer="buildings");

register = readtable(registerFile, ...
    TextType="string", ...
    VariableNamingRule="preserve");

mapping = readtable(matchFile, ...
    TextType="string", ...
    VariableNamingRule="preserve");

fprintf("\n=== 데이터 로딩 완료 ===\n");
fprintf("OSM 건물 수: %d\n", height(buildings));
fprintf("표제부 기록 수: %d\n", height(register));
fprintf("기존 매칭 기록: %d\n", height(mapping));

%% 3. 원본 높이 백업

buildingsOriginal = buildings;

originalHeights = double(buildings.MaxHeight);

% 이름 정리
osmNames = strtrim(string(buildings.Name));
mapNames = strtrim(string(mapping.osm_name));

% 매칭 파일 높이를 숫자형으로 변환
mapHeights = str2double(string(mapping.height_m));

% 적용 결과 추적
updated = false(height(buildings), 1);
heightSource = repmat("original", height(buildings), 1);

updateLog = table();

%% 4. 표제부 실제 높이 자동 적용

fprintf("\n=== 표제부 높이 적용 ===\n");

for i = 1:height(mapping)

    % 표제부 실제 높이만 사용
    if mapping.height_source(i) ~= "register"
        continue;
    end

    % 불확실한 의미 기반 매칭은 제외
    quality = string(mapping.match_quality(i));

    if contains(lower(quality), "verify")
        fprintf("검증 필요, 적용 제외: %s\n", ...
            mapNames(i));
        continue;
    end

    name = mapNames(i);
    newHeight = mapHeights(i);

    if ismissing(name) || strlength(name)==0
        continue;
    end

    if ~isfinite(newHeight) || newHeight<=0
        continue;
    end

    % OSM 건물명과 매칭
    idx = find(osmNames == name);

    % 동일 이름이 하나뿐인 경우 적용
    if numel(idx) ~= 1
        fprintf("매칭 확인 필요: %s\n", name);
        continue;
    end

    oldHeight = double(buildings.MaxHeight(idx));

    % 건물 높이 수정
    buildings.MaxHeight(idx) = newHeight;

    updated(idx) = true;
    heightSource(idx) = "register";

    % 변경 기록
    newRow = table( ...
        name, oldHeight, newHeight, ...
        string(mapping.register_name(i)), ...
        'VariableNames', ...
        {'Building','OldHeight_m', ...
         'NewHeight_m','RegisterName'});

    updateLog = [updateLog; newRow];

    fprintf("%s : %.2f m -> %.2f m\n", ...
        name, oldHeight, newHeight);
end

%% 5. 건물 재질 설정

% 기존 Material 속성이 없으면 생성
if ~ismember("Material", ...
        string(buildings.Properties.VariableNames))

    buildings.Material = repmat( ...
        "concrete", height(buildings), 1);
else
    buildings.Material = string(buildings.Material);
end

% 표제부에서 철근콘크리트로 확인된 건물은
% concrete 재질을 지정
%
% 주의:
% 구조코드명은 건물의 주요 구조를 의미하며
% 외벽의 상세 재료 특성을 완전히 나타내지는 않음.

regNames = strtrim(string(register.("동명칭")));
regStructure = string(register.("구조코드명"));

% 이름이 명확히 일치하는 건물만 처리
for i = 1:height(buildings)

    name = osmNames(i);

    if ismissing(name) || strlength(name)==0
        continue;
    end

    idx = find(regNames == name);

    if numel(idx) ~= 1
        continue;
    end

    structure = regStructure(idx);

    if contains(structure, "철근콘크리트")
        buildings.Material(i) = "concrete";
    end
end

%% 6. 수정 결과 출력

fprintf("\n=== 높이 수정 결과 ===\n");

disp(updateLog);

fprintf("실제 높이 적용: %d개\n", sum(updated));

fprintf("\n=== 주요 건물 높이 ===\n");

targetNames = [
    "미래관"
    "체육관"
    "북악관"
    "법학관"
    "성곡도서관"
    "조형관"
    "과학관"
    "본부관"
    "종합복지관"
    "예술관"
    "공학관"
];

idx = ismember(osmNames, targetNames);

disp(buildings(idx, ...
    ["Name","MaxHeight","Material"]));

%% 7. 수정 내역 저장

save(fullfile(outputDir, ...
    "kookmin_buildings_updated.mat"), ...
    "buildings", "buildingsOriginal", ...
    "register", "mapping", "updated");

writetable(updateLog, ...
    fullfile(outputDir, "height_update_result.csv"));

% 전체 건물의 높이 출처도 함께 저장
auditTable = table( ...
    osmNames, originalHeights, ...
    double(buildings.MaxHeight), ...
    heightSource, string(buildings.Material), ...
    'VariableNames', ...
    {'Name','OriginalHeight_m', ...
     'UpdatedHeight_m','HeightSource','Material'});

writetable(auditTable, ...
    fullfile(outputDir, "building_height_audit.csv"));

%% 8. 수정된 3D 지도 생성

viewer = siteviewer( ...
    Buildings=buildings, ...
    Basemap="satellite");

fprintf("\n=== 완료 ===\n");
fprintf("건물 높이 자동 적용 완료\n");
fprintf("수정된 3D 지도 생성 완료\n");
fprintf("저장 위치: %s\n", outputDir);
