# Hardcover reading activity

Some CrossPoint Sync versions return title/author/cover for Currently Reading but
omit the user-book update timestamp. Shelf can display those titles, but cannot
know when reading status actually changed. Fetching the catalog is not reading
activity and must not be used as a substitute timestamp.

`hardcover-activity.patch` adds the optional `updatedAt` field to the adapter's
Currently Reading query and `ExternalBook` type. Apply it to a compatible
CrossPoint Sync checkout, build its normal Docker image, and redeploy with the
existing environment, port mappings, and persistent `/data` volume. The patch
contains no credentials. If the server already returns an equivalent timestamp,
no patch is needed. This does not add a live BookPlayer playback-position API:
BookPlayer's existing Hardcover integration supplies reading status.

The local deployment was updated and its previous stopped container retained for
rollback. Its candidates endpoint returned real update timestamps for all 17
currently-reading books after deployment. Source IDs and library data are unchanged.
