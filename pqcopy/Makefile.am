# Copyright 2009 University Corporation for Atmospheric Research
#
# This file is part of the LDM package.  See the file COPYRIGHT
# in the top-level source-directory of the package for copying and
# redistribution conditions.
#
## Process this file with automake to produce Makefile.in

PQ_SUBDIR	= @PQ_SUBDIR@
EXTRA_DIST	= pqcopy.1
bin_PROGRAMS	= pqcopy
CPPFLAGS	= \
    -I$(top_srcdir)/ulog \
    -I$(top_builddir)/protocol -I$(top_srcdir)/protocol \
    -I$(top_builddir)/registry -I$(top_srcdir)/registry \
    -I$(top_srcdir)/pq \
    -I$(top_srcdir)/misc \
    -I$(top_srcdir)
pqcopy_LDADD	= $(top_builddir)/lib/libldm.la
dist_man1_MANS	= pqcopy.1
TAGS_FILES	= \
    ../$(PQ_SUBDIR)/*.c ../$(PQ_SUBDIR)/*.h \
    ../protocol/*.c ../protocol/*.h \
    ../registry/*.c ../registry/*.h \
    ../ulog/*.c ../ulog/*.h \
    ../misc/*.c ../misc/*.h \
    ../rpc/*.c ../rpc/*.h
