
%% OSM 건물 데이터 누락 현황 확인
clear; clc;

projectRoot = fileparts(fileparts(mfilename("fullpath")));
doc = xmlread(fullfile(projectRoot,"data","simulation","raw","map.osm"));

% Way와 Relation 객체 확인
ways = doc.getElementsByTagName("way");
rels = doc.getElementsByTagName("relation");

items = {ways, rels};

names = strings(0,1);
heights = strings(0,1);
levels = strings(0,1);

for g = 1:numel(items)
    objects = items{g};

    for i = 0:objects.getLength-1
        obj = objects.item(i);
        tags = obj.getElementsByTagName("tag");

        info = struct();

        for j = 0:tags.getLength-1
            tag = tags.item(j);
            k = char(tag.getAttribute("k"));
            v = string(char(tag.getAttribute("v")));

            switch k
                case "building"
                    info.building = v;
                case "name"
                    info.name = v;
                case "height"
                    info.height = v;
                case "building:levels"
                    info.levels = v;
            end
        end

        if ~isfield(info, "building")
            continue;
        end

        if ~isfield(info, "name")
            info.name = "(이름 없음)";
        end
        if ~isfield(info, "height")
            info.height = "";
        end
        if ~isfield(info, "levels")
            info.levels = "";
        end

        names(end+1,1) = info.name;
        heights(end+1,1) = info.height;
        levels(end+1,1) = info.levels;
    end
end

T = table(names, heights, levels, ...
    'VariableNames', ...
    {'Building','Height_m','Floors'});

T.MissingHeight = T.Height_m == "";
T.MissingFloors = T.Floors == "";

disp(T);
fprintf("건물 객체 수: %d\n", height(T));
fprintf("높이 누락: %d\n", sum(T.MissingHeight));
fprintf("층수 누락: %d\n", sum(T.MissingFloors));
