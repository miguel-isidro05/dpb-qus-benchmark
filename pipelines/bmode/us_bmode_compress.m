function image_db = us_bmode_compress(envelope,reference,range_db)
%US_BMODE_COMPRESS Visual solamente. No modifica RF/envolvente QUS.
validateattributes(reference,{'numeric'},{'real','scalar','finite','positive'});
validateattributes(range_db,{'numeric'},{'real','scalar','finite','positive'});
image_db=20*(log10(max(envelope,realmin('double')))-log10(reference));
image_db=min(0,max(-range_db,image_db));
end
