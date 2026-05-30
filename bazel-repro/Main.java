// Deliberately trivial. The point is not what this code does — it is that
// running it requires launching the remotejdk_25 JVM out of Bazel's runfiles
// symlink tree, where bin\server\classes.jsa is a symlink.
public class Main {
    public static void main(String[] args) {
        System.out.println("hello from the runfiles JDK");
    }
}
