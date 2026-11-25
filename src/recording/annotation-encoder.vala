/*
This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

namespace Peek.Recording {

  /**
  * Creates the file to be saved from a capture and the items drawn on it.
  */
  public interface AnnotationEncoder : Object {
    public abstract bool is_cancelled { get; }

    public abstract void cancel ();
  }

}
