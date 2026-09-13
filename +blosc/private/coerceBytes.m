function [raw, typesize] = coerceBytes(bytesIn, typesizeIn)
%COERCEBYTES Normalise an encode input into uint8 bytes + typesize.
%
%   [RAW, TYPESIZE] = COERCEBYTES(BYTESIN, TYPESIZEIN)
%
%   Rules:
%     * BYTESIN is uint8      -> RAW = bytesIn(:), TYPESIZE = TYPESIZEIN
%                                or 1 if TYPESIZEIN is 0.
%     * BYTESIN is any other  -> RAW = typecast(bytesIn(:), 'uint8'),
%       numeric type            TYPESIZE = TYPESIZEIN if given (>0),
%                               else the class's byte size.
%
%   Called only from within +blosc (private/ scoping).

    if isa(bytesIn, 'uint8')
        raw = bytesIn(:);
        if typesizeIn > 0
            typesize = typesizeIn;
        else
            typesize = 1;
        end
    elseif isnumeric(bytesIn) || islogical(bytesIn)
        raw = typecast(bytesIn(:), 'uint8');
        if typesizeIn > 0
            typesize = typesizeIn;
        else
            typesize = elementSize(class(bytesIn));
        end
    else
        error('matlab_blosc:encode:BadInput', ...
            'Input must be a numeric or logical array, got %s.', ...
            class(bytesIn));
    end

    if mod(numel(raw), typesize) ~= 0
        error('matlab_blosc:encode:LengthMismatch', ...
            ['Byte length %d is not a multiple of typesize %d; ' ...
             'shuffle would leave a partial element.'], ...
            numel(raw), typesize);
    end
end

function n = elementSize(cls)
    switch cls
        case {'uint8','int8','logical'}
            n = 1;
        case {'uint16','int16'}
            n = 2;
        case {'uint32','int32','single'}
            n = 4;
        case {'uint64','int64','double'}
            n = 8;
        otherwise
            error('matlab_blosc:encode:UnknownClass', ...
                ['Class %s has no obvious element size; pass ' ...
                 '''typesize'' explicitly.'], cls);
    end
end
